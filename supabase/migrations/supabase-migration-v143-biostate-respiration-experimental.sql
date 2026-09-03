-- ════════════════════════════════════════════════════════════════════════════
--  v143 — Biostate RESPIRATION detector  (EXPERIMENTAL, the hard one)
--
--  Detector #3 (last). Breathing rate is the WEAKEST signal on this data: RR-derived
--  respiration is undersampled at rest (HR~60, ~65% beat coverage → Nyquist edge,
--  was bimodal 7↔21bpm on short windows). Two things changed the plan:
--    1. At 180-240s windows with good coverage the RR-periodogram gives SANE values
--       (validated: sober 14.7, drunk 18.3 bpm — textbook) — the bimodal flip was a
--       short-window artifact.
--    2. Whoop's native strap_resp reads a clamped ~23-24 for this user even in sleep
--       (junk) — so the originally-planned "trust strap in sleep" half is unreliable.
--  → RR-derived periodogram is PRIMARY (rolling-median smoothed across recent calls to
--    kill residual jitter), strap_resp is a sanity cross-check / fallback only.
--
--  Honest output: method, confidence, and an explicit ± error band. This is the
--  detector most likely to be wrong; it says so. experimental:true.
-- ════════════════════════════════════════════════════════════════════════════

-- widen the respiration window: 60s was too few breaths for a stable periodogram
UPDATE public.biostate_config
   SET cfg = jsonb_set(cfg, '{windows_s,respiration}', '180'::jsonb, true), updated_at = now()
 WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid;

DROP FUNCTION IF EXISTS public.respiration_now(uuid, timestamptz, boolean);
CREATE OR REPLACE FUNCTION public.respiration_now(
  p_user    uuid        DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_end     timestamptz DEFAULT now(),
  p_persist boolean     DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg       jsonb;
  v_rcfg      jsonb;
  v_qcfg      jsonb;
  v_win_s     int;
  v_min_bpm   numeric;
  v_max_bpm   numeric;
  v_f         jsonb;
  v_rr_resp   numeric;
  v_strap     numeric;
  v_spec_ok   boolean;
  v_cov       numeric;
  v_nbeats    int;
  v_qscore    numeric;
  v_stage     text;
  v_act       text;
  v_rr_ok     boolean;
  v_strap_ok  boolean;
  v_est       numeric;
  v_method    text;
  v_conf      numeric;
  v_err       numeric;
  v_agree     boolean := false;
  v_prev      public.biostate_state%ROWTYPE;
  v_recent    jsonb;
  v_arr       numeric[];
  v_smoothed  numeric;
  v_out       jsonb;
BEGIN
  SELECT cfg INTO v_cfg FROM public.biostate_config WHERE user_id = p_user;
  v_rcfg := COALESCE(v_cfg->'respiration', '{}'::jsonb);
  v_qcfg := COALESCE(v_cfg->'quality', '{}'::jsonb);
  v_win_s := COALESCE((v_cfg#>>'{windows_s,respiration}')::int, 180);
  v_min_bpm := COALESCE((v_rcfg->>'min_bpm')::numeric, 7.2);
  v_max_bpm := COALESCE((v_rcfg->>'max_bpm')::numeric, 24);

  v_f       := public.biostate_features_now(p_user, v_win_s, p_end);
  v_rr_resp := (v_f->>'resp_rate')::numeric;
  v_strap   := (v_f->>'strap_resp')::numeric;
  v_spec_ok := (v_f#>>'{quality,spectral_ok}')::boolean;
  v_cov     := (v_f#>>'{quality,coverage_frac}')::numeric;
  v_nbeats  := (v_f#>>'{quality,n_beats}')::int;
  v_qscore  := (v_f#>>'{quality,score}')::numeric;
  v_stage   := v_f->>'sleep_stage';
  v_act     := v_f->>'activity_state';

  -- which sources are usable
  v_rr_ok    := v_rr_resp IS NOT NULL AND v_rr_resp BETWEEN v_min_bpm AND 30
                 AND COALESCE(v_spec_ok,false)
                 AND COALESCE(v_nbeats,0) >= COALESCE((v_qcfg->>'min_beats')::int,20);
  -- strap "sane" excludes the 23-24 clamp this user's strap emits
  v_strap_ok := v_strap IS NOT NULL AND v_strap BETWEEN 8 AND 22;

  IF NOT v_rr_ok AND NOT v_strap_ok THEN
    RETURN jsonb_build_object(
      'experimental', true, 'detector', 'respiration', 'ts', p_end,
      'resp_rate', NULL, 'method', 'none', 'confidence', 0,
      'reason', 'no_usable_source',
      'rr_derived', v_rr_resp, 'strap', v_strap, 'spectral_ok', v_spec_ok,
      'quality', v_f->'quality');
  END IF;

  -- pick primary
  IF v_rr_ok THEN
    v_est := v_rr_resp; v_method := 'rr_periodogram';
  ELSE
    v_est := v_strap;   v_method := 'strap_fallback';
  END IF;

  -- agreement when both sane and within 3 bpm
  IF v_rr_ok AND v_strap_ok AND abs(v_rr_resp - v_strap) <= 3 THEN v_agree := true; END IF;

  -- confidence: RR-derived is inherently uncertain at rest; agreement & coverage lift it
  v_conf := CASE WHEN v_rr_ok THEN 0.55 ELSE 0.35 END;
  IF v_agree THEN v_conf := v_conf + 0.30; END IF;
  IF COALESCE(v_cov,0) > 0.8 THEN v_conf := v_conf + 0.10; END IF;
  IF v_method = 'strap_fallback' THEN v_conf := LEAST(v_conf, 0.50); END IF;
  v_conf := LEAST(1.0, GREATEST(0.0, v_conf));

  -- ── rolling median across recent raw estimates (kills residual bimodal jitter) ──
  v_smoothed := v_est;
  SELECT * INTO v_prev FROM public.biostate_state WHERE user_id=p_user AND detector='respiration';
  IF FOUND AND v_prev.payload ? 'recent_raw' THEN
    v_recent := v_prev.payload->'recent_raw';
  ELSE
    v_recent := '[]'::jsonb;
  END IF;
  -- build array of [recent... , current], keep last 5
  v_arr := ARRAY(SELECT x::numeric FROM jsonb_array_elements_text(v_recent) x) || v_est;
  IF array_length(v_arr,1) > 5 THEN
    v_arr := v_arr[(array_length(v_arr,1)-4):array_length(v_arr,1)];
  END IF;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY u) INTO v_smoothed FROM unnest(v_arr) u;

  -- error band scales inversely with confidence (± bpm)
  v_err := round((1 + 4 * (1 - v_conf))::numeric, 1);

  v_out := jsonb_build_object(
    'experimental', true,
    'detector', 'respiration',
    'ts', p_end,
    'window_s', v_win_s,
    'resp_rate', round(v_smoothed::numeric, 1),
    'resp_raw', round(v_est::numeric, 1),
    'error_bpm', v_err,
    'range_low', round((v_smoothed - v_err)::numeric, 1),
    'range_high', round((v_smoothed + v_err)::numeric, 1),
    'method', v_method,
    'confidence', round(v_conf::numeric, 2),
    'rr_derived', round(COALESCE(v_rr_resp,0)::numeric, 1),
    'strap', v_strap,
    'strap_usable', v_strap_ok,
    'sources_agree', v_agree,
    'spectral_ok', v_spec_ok,
    'sleep_stage', v_stage,
    'activity_state', v_act,
    'n_samples_smoothed', COALESCE(array_length(v_arr,1),1),
    'quality', v_f->'quality'
  );

  IF p_persist THEN
    -- carry the rolling buffer in payload.recent_raw
    v_out := jsonb_set(v_out, '{recent_raw}', to_jsonb(v_arr));
    INSERT INTO public.biostate_state
      (user_id, detector, updated_at, committed_stage, committed_value, committed_at,
       raw_stage, raw_since, confidence, experimental, payload)
    VALUES
      (p_user, 'respiration', now(), NULL, v_smoothed, p_end, NULL, p_end, v_conf, true, v_out)
    ON CONFLICT (user_id, detector) DO UPDATE SET
      updated_at      = now(),
      committed_value = EXCLUDED.committed_value,
      committed_at    = EXCLUDED.committed_at,
      confidence      = EXCLUDED.confidence,
      payload         = EXCLUDED.payload;
  END IF;

  RETURN v_out;
END $$;

GRANT EXECUTE ON FUNCTION public.respiration_now(uuid, timestamptz, boolean) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.respiration_now(uuid, timestamptz, boolean) IS
  'EXPERIMENTAL biostate detector (weakest signal). Breathing rate from RR-interval periodogram (primary, rolling-median smoothed) with Whoop strap_resp as cross-check/fallback. Reports method + confidence + explicit ± error band. RR-respiration is undersampled at rest — trust the confidence field. experimental:true — DO NOT consume as truth.';
