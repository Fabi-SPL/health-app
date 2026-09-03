-- ════════════════════════════════════════════════════════════════════════════
--  v141 — Biostate DRUNK detector  +  EXPERIMENTAL marking  +  state/hysteresis
--
--  Detector #1 of the biostate engine (build order: drunk → arousal → respiration).
--  Robust because it leans on the TIME-DOMAIN HRV ladder calibrated in the C#
--  Magic Chatbox ClassifyDrunk + validated here on Fabi's only server-side labeled
--  drunk night (Jun14): clean light-sleep RMSSD 36-40 vs sober 52-89  →  ratio
--  0.65-0.73  →  stage 2-3, matching the historical Apr/May calibration.
--
--  ⚠️ EXPERIMENTAL (Fabi's explicit requirement 2026-06-15): everything this engine
--  emits is flagged experimental:true so NOTHING downstream consumes it as ground
--  truth for "how Fabi feels". cfg.experimental=true, state_truth_log.experimental,
--  biostate_state.experimental, and every RPC payload carries the flag.
--
--  Widmark BAC path is DEFERRED: alcohol_flags is a per-DAY boolean (manual_drinking),
--  not a per-drink log — no drink count/timing exists server-side. So drunk_now is
--  the HRV ladder (+ DFA booster + HR-rise corroboration), gated by is_alcohol_mode.
--
--  Reused (verified to exist): biostate_features_now(uuid,int,timestamptz),
--  is_alcohol_mode(uuid,date), personal_priors(param: hrv_baseline/rhr_baseline/
--  alcohol_hr_offset). personal_model/get_personal_model return null → not used.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. EXPERIMENTAL marking ──────────────────────────────────────────────────
UPDATE public.biostate_config
   SET cfg = jsonb_set(cfg, '{experimental}', 'true'::jsonb, true),
       updated_at = now()
 WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid;

ALTER TABLE public.state_truth_log
  ADD COLUMN IF NOT EXISTS experimental boolean NOT NULL DEFAULT true;

-- ── 2. biostate_state ─────────────────────────────────────────────────────────
-- One row per (user, detector). Holds the hysteresis memory + last full read so the
-- VRChat broadcaster / clients can read "current state" without recomputing.
-- raw_*   = the unfiltered stage the latest window produced + when it first appeared.
-- committed_* = the hysteresis-smoothed stage actually surfaced (rise/fall holds).
CREATE TABLE IF NOT EXISTS public.biostate_state (
  user_id         uuid        NOT NULL,
  detector        text        NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  committed_stage int,
  committed_value numeric,
  committed_at    timestamptz,
  raw_stage       int,
  raw_since       timestamptz,
  confidence      numeric,
  experimental    boolean     NOT NULL DEFAULT true,
  payload         jsonb,
  PRIMARY KEY (user_id, detector)
);

ALTER TABLE public.biostate_state ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bss_own       ON public.biostate_state;
DROP POLICY IF EXISTS bss_anon_read ON public.biostate_state;
CREATE POLICY bss_own       ON public.biostate_state FOR ALL
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY bss_anon_read ON public.biostate_state FOR SELECT
  USING (user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);

-- ── 3. drunk_now() ────────────────────────────────────────────────────────────
-- p_persist=false for replay/validation (won't clobber live hysteresis state).
DROP FUNCTION IF EXISTS public.drunk_now(uuid, timestamptz, boolean);
CREATE OR REPLACE FUNCTION public.drunk_now(
  p_user    uuid        DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_end     timestamptz DEFAULT now(),
  p_persist boolean     DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg        jsonb;
  v_dr         jsonb;
  v_qcfg       jsonb;
  v_win_s      int;
  v_alc_on     boolean;
  v_gated      boolean;
  v_f          jsonb;
  v_rmssd      numeric;
  v_sdnn       numeric;
  v_hr         numeric;
  v_dfa        numeric;
  v_qscore     numeric;
  v_cov        numeric;
  v_nbeats     int;
  v_stage_lbl  text;
  v_act        text;
  v_base_rmssd numeric;
  v_base_hr    numeric;
  v_alc_off    numeric;
  v_ratios     numeric[];
  v_ratio      numeric;
  v_biostage   int;
  v_dfa_thresh numeric;
  v_dfa_fired  boolean := false;
  v_hr_rise    numeric;
  v_hr_corrob  boolean := false;
  v_raw        int;
  v_conf       numeric;
  v_labels     text[] := ARRAY['sober','buzzed','tipsy','drunk','wasted'];
  v_prev       public.biostate_state%ROWTYPE;
  v_committed  int;
  v_raw_since  timestamptz;
  v_hold       int;
  v_out        jsonb;
BEGIN
  -- config
  SELECT cfg INTO v_cfg FROM public.biostate_config WHERE user_id = p_user;
  v_dr   := COALESCE(v_cfg->'drunk', '{}'::jsonb);
  v_qcfg := COALESCE(v_cfg->'quality', '{}'::jsonb);
  v_win_s := COALESCE((v_cfg#>>'{windows_s,drunk}')::int, 180);
  v_gated := COALESCE((v_dr->>'gated_by_alcohol_mode')::boolean, true);

  -- alcohol-mode gate: if gated and not in alcohol mode → forced sober, no compute
  v_alc_on := COALESCE(public.is_alcohol_mode(p_user, (p_end AT TIME ZONE 'Europe/Berlin')::date), false);
  IF v_gated AND NOT v_alc_on THEN
    RETURN jsonb_build_object(
      'experimental', true, 'detector', 'drunk', 'ts', p_end,
      'gated', true, 'alcohol_mode', false,
      'stage', 0, 'label', 'sober', 'confidence', 1.0,
      'reason', 'alcohol_mode_off_forced_sober'
    );
  END IF;

  -- features
  v_f      := public.biostate_features_now(p_user, v_win_s, p_end);
  v_rmssd  := (v_f->>'rmssd')::numeric;
  v_sdnn   := (v_f->>'sdnn')::numeric;
  v_hr     := (v_f->>'mean_hr')::numeric;
  v_dfa    := (v_f->>'dfa_alpha1')::numeric;
  v_qscore := (v_f#>>'{quality,score}')::numeric;
  v_cov    := (v_f#>>'{quality,coverage_frac}')::numeric;
  v_nbeats := (v_f#>>'{quality,n_beats}')::int;
  v_stage_lbl := v_f->>'sleep_stage';
  v_act    := v_f->>'activity_state';

  -- hard quality gate — drunk garbage from low-coverage windows (rmssd 150 "awake",
  -- cov 0.06) must NOT be staged. Return unknown instead of guessing.
  IF v_rmssd IS NULL
     OR v_qscore IS NULL
     OR v_qscore < COALESCE((v_qcfg->>'min_quality_score')::numeric, 0.4)
     OR COALESCE(v_cov,0) < COALESCE((v_qcfg->>'min_coverage_frac')::numeric, 0.4)
     OR COALESCE(v_nbeats,0) < COALESCE((v_qcfg->>'min_beats')::int, 20) THEN
    RETURN jsonb_build_object(
      'experimental', true, 'detector', 'drunk', 'ts', p_end,
      'gated', false, 'alcohol_mode', v_alc_on,
      'stage', NULL, 'label', 'unknown', 'confidence', 0,
      'reason', 'low_quality_window',
      'quality', v_f->'quality',
      'rmssd', round(COALESCE(v_rmssd,0)::numeric, 1)
    );
  END IF;

  -- personal anchors (Bayesian priors; fallbacks from cfg)
  SELECT mu INTO v_base_rmssd FROM public.personal_priors WHERE user_id=p_user AND param='hrv_baseline';
  v_base_rmssd := COALESCE(v_base_rmssd, (v_dr->>'sober_rmssd_fallback')::numeric, 55);
  SELECT mu INTO v_base_hr FROM public.personal_priors WHERE user_id=p_user AND param='rhr_baseline';
  v_base_hr := COALESCE(v_base_hr, 51);
  SELECT mu INTO v_alc_off FROM public.personal_priors WHERE user_id=p_user AND param='alcohol_hr_offset';
  v_alc_off := COALESCE(v_alc_off, 10);

  -- RMSSD ratio ladder (calibrated C# ClassifyDrunk thresholds)
  v_ratios := ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_dr->'rmssd_ratios','[0.91,0.82,0.64,0.55]'::jsonb))::numeric);
  v_ratio  := v_rmssd / NULLIF(v_base_rmssd,0);
  v_biostage := CASE
    WHEN v_ratio >= v_ratios[1] THEN 0
    WHEN v_ratio >= v_ratios[2] THEN 1
    WHEN v_ratio >= v_ratios[3] THEN 2
    WHEN v_ratio >= v_ratios[4] THEN 3
    ELSE 4 END;

  -- DFA-α1 booster: alcohol drives DFA toward uncorrelated. Fires mainly AWAKE
  -- (awake DFA ~1.0 → <0.75 when drunk); during sleep DFA runs high so it rarely
  -- fires there, which is correct (RMSSD ladder carries sleep detection).
  v_dfa_thresh := COALESCE((v_dr->>'dfa_alpha1_alcohol_thresh')::numeric, 0.75);
  IF v_dfa IS NOT NULL AND v_dfa > 0.1 AND v_dfa < v_dfa_thresh AND v_biostage >= 1 THEN
    v_dfa_fired := true;
    v_biostage := LEAST(v_biostage + 1, 4);
  END IF;

  v_raw := v_biostage;

  -- HR-rise corroboration (confidence only, never stage): alcohol_hr_offset prior
  -- says alcohol lifts HR ~10bpm at BAC peak. Late-night it metabolizes away, so use
  -- a soft 0.4× threshold and only let it ADJUST confidence.
  v_hr_rise := v_hr - v_base_hr;
  IF v_hr_rise >= 0.4 * v_alc_off THEN v_hr_corrob := true; END IF;

  -- ── hysteresis ──────────────────────────────────────────────────────────────
  SELECT * INTO v_prev FROM public.biostate_state WHERE user_id=p_user AND detector='drunk';
  IF NOT FOUND OR v_prev.committed_stage IS NULL THEN
    v_committed := v_raw; v_raw_since := p_end;
  ELSE
    -- track when the raw stage last changed
    IF v_prev.raw_stage IS DISTINCT FROM v_raw THEN
      v_raw_since := p_end;
    ELSE
      v_raw_since := COALESCE(v_prev.raw_since, p_end);
    END IF;
    -- asymmetric hold: rising intoxication confirms fast, sobering confirms slow
    v_hold := CASE WHEN v_raw > v_prev.committed_stage
                   THEN COALESCE((v_dr#>>'{hysteresis_s,rise_hold}')::int, 45)
                   ELSE COALESCE((v_dr#>>'{hysteresis_s,fall_hold}')::int, 150) END;
    IF v_raw = v_prev.committed_stage THEN
      v_committed := v_prev.committed_stage;
    ELSIF EXTRACT(EPOCH FROM (p_end - v_raw_since)) >= v_hold THEN
      v_committed := v_raw;
    ELSE
      v_committed := v_prev.committed_stage;
    END IF;
  END IF;

  -- confidence: quality-driven, nudged by corroboration agreement
  v_conf := LEAST(1.0, GREATEST(0.0, v_qscore));
  IF v_committed >= 2 AND v_hr_corrob THEN v_conf := LEAST(1.0, v_conf + 0.10); END IF;
  IF v_dfa_fired THEN v_conf := LEAST(1.0, v_conf + 0.05); END IF;
  IF v_committed >= 1 AND NOT v_hr_corrob AND v_committed >= 3 THEN
    v_conf := GREATEST(0.0, v_conf - 0.10);  -- high stage but no HR support → soften
  END IF;

  v_out := jsonb_build_object(
    'experimental', true,
    'detector', 'drunk',
    'ts', p_end,
    'window_s', v_win_s,
    'gated', false,
    'alcohol_mode', v_alc_on,
    'stage', v_committed,
    'label', v_labels[v_committed + 1],
    'raw_stage', v_raw,
    'raw_label', v_labels[v_raw + 1],
    'confidence', round(v_conf::numeric, 2),
    'rmssd', round(v_rmssd::numeric, 1),
    'baseline_rmssd', round(v_base_rmssd::numeric, 1),
    'rmssd_ratio', round(v_ratio::numeric, 3),
    'sdnn', round(v_sdnn::numeric, 1),
    'hr', round(v_hr::numeric, 1),
    'baseline_hr', round(v_base_hr::numeric, 1),
    'hr_rise', round(v_hr_rise::numeric, 1),
    'hr_corroborated', v_hr_corrob,
    'dfa_alpha1', round(COALESCE(v_dfa,0)::numeric, 2),
    'dfa_booster_fired', v_dfa_fired,
    'sleep_stage', v_stage_lbl,
    'activity_state', v_act,
    'quality', v_f->'quality'
  );

  -- persist hysteresis state + current read (skip on replay)
  IF p_persist THEN
    INSERT INTO public.biostate_state
      (user_id, detector, updated_at, committed_stage, committed_value, committed_at,
       raw_stage, raw_since, confidence, experimental, payload)
    VALUES
      (p_user, 'drunk', now(), v_committed, v_ratio, p_end,
       v_raw, v_raw_since, v_conf, true, v_out)
    ON CONFLICT (user_id, detector) DO UPDATE SET
      updated_at      = now(),
      committed_stage = EXCLUDED.committed_stage,
      committed_value = EXCLUDED.committed_value,
      committed_at    = EXCLUDED.committed_at,
      raw_stage       = EXCLUDED.raw_stage,
      raw_since       = EXCLUDED.raw_since,
      confidence      = EXCLUDED.confidence,
      payload         = EXCLUDED.payload;
  END IF;

  RETURN v_out;
END $$;

GRANT EXECUTE ON FUNCTION public.drunk_now(uuid, timestamptz, boolean) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.drunk_now(uuid, timestamptz, boolean) IS
  'EXPERIMENTAL biostate detector. Real-time intoxication stage 0-4 from time-domain HRV (RMSSD ratio vs personal baseline) + DFA booster + HR-rise corroboration, gated by is_alcohol_mode, smoothed by asymmetric hysteresis. Output is experimental:true — DO NOT consume as ground truth for mood/state. Calibrated from C# ClassifyDrunk + validated on Jun14 drunk night.';
COMMENT ON TABLE public.biostate_state IS
  'EXPERIMENTAL. Per-(user,detector) hysteresis memory + last read cache for the biostate engine. Do not consume downstream as truth.';
