-- ════════════════════════════════════════════════════════════════════════════
--  v142 — Biostate AROUSAL detector  (EXPERIMENTAL)
--
--  Detector #2 (build order drunk → arousal → respiration). Continuous arousal
--  level 0-10 (5 = personal baseline / neutral) from a TIME-DOMAIN fusion, because
--  on Fabi's data frequency-domain (LF/HF) is noisy and even inverts vs total power.
--
--  Research grounding (dr-20260615 biostate): personalized %-change-from-baseline
--  of RMSSD + HR is the robust 80-84% arousal signal; LF/HF kept only as a
--  quality-gated side reading, never in the score. No labeled calm/stressed windows
--  exist yet → this self-calibrates through state_truth_log + update_personal_prior.
--
--  NOT gated (always-on). Score:
--    a_rmssd = rmssd_drop_% / stress_rmssd_drop_pct   (1.0 = at stress threshold)
--    a_hr    = hr_rise_bpm  / stress_hr_rise_bpm
--    core    = avg(a_rmssd, a_hr)        (negative = below baseline = relaxed)
--    arousal = clamp(5 + 2.5*core, 0, 10)
--  Baselines taken from the spine (current_state: baseline_rmssd≈52.95, baseline_hr≈58),
--  fallback to personal_priors. Light EMA smoothing via biostate_state.
--
--  ⚠️ experimental:true on every payload — do NOT consume as truth for mood/state.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.arousal_now(uuid, timestamptz, boolean);
CREATE OR REPLACE FUNCTION public.arousal_now(
  p_user    uuid        DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_end     timestamptz DEFAULT now(),
  p_persist boolean     DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg        jsonb;
  v_ar         jsonb;
  v_qcfg       jsonb;
  v_win_s      int;
  v_f          jsonb;
  v_rmssd      numeric;
  v_hr         numeric;
  v_sdnn       numeric;
  v_lf_hf      numeric;
  v_dfa        numeric;
  v_qscore     numeric;
  v_cov        numeric;
  v_nbeats     int;
  v_spec_ok    boolean;
  v_stage_lbl  text;
  v_act        text;
  v_base_rmssd numeric;
  v_base_hr    numeric;
  v_drop_pct_thr numeric;
  v_hr_rise_thr  numeric;
  v_rmssd_ratio  numeric;
  v_drop_pct   numeric;
  v_hr_rise    numeric;
  v_a_rmssd    numeric;
  v_a_hr       numeric;
  v_core       numeric;
  v_arousal    numeric;
  v_band       text;
  v_emoji      text;
  v_conf       numeric;
  v_disagree   boolean := false;
  v_bv_val     numeric;
  v_bv_lbl     text;
  v_prev       public.biostate_state%ROWTYPE;
  v_smoothed   numeric;
  v_out        jsonb;
BEGIN
  SELECT cfg INTO v_cfg FROM public.biostate_config WHERE user_id = p_user;
  v_ar   := COALESCE(v_cfg->'arousal', '{}'::jsonb);
  v_qcfg := COALESCE(v_cfg->'quality', '{}'::jsonb);
  v_win_s := COALESCE((v_cfg#>>'{windows_s,arousal}')::int, 240);
  v_drop_pct_thr := COALESCE((v_ar->>'stress_rmssd_drop_pct')::numeric, 20);
  v_hr_rise_thr  := COALESCE((v_ar->>'stress_hr_rise_bpm')::numeric, 10);

  v_f      := public.biostate_features_now(p_user, v_win_s, p_end);
  v_rmssd  := (v_f->>'rmssd')::numeric;
  v_hr     := (v_f->>'mean_hr')::numeric;
  v_sdnn   := (v_f->>'sdnn')::numeric;
  v_lf_hf  := (v_f->>'lf_hf')::numeric;
  v_dfa    := (v_f->>'dfa_alpha1')::numeric;
  v_qscore := (v_f#>>'{quality,score}')::numeric;
  v_cov    := (v_f#>>'{quality,coverage_frac}')::numeric;
  v_nbeats := (v_f#>>'{quality,n_beats}')::int;
  v_spec_ok:= (v_f#>>'{quality,spectral_ok}')::boolean;
  v_stage_lbl := v_f->>'sleep_stage';
  v_act    := v_f->>'activity_state';

  -- hard quality gate
  IF v_rmssd IS NULL OR v_hr IS NULL OR v_qscore IS NULL
     OR v_qscore < COALESCE((v_qcfg->>'min_quality_score')::numeric, 0.4)
     OR COALESCE(v_cov,0) < COALESCE((v_qcfg->>'min_coverage_frac')::numeric, 0.4)
     OR COALESCE(v_nbeats,0) < COALESCE((v_qcfg->>'min_beats')::int, 20) THEN
    RETURN jsonb_build_object(
      'experimental', true, 'detector', 'arousal', 'ts', p_end,
      'arousal', NULL, 'band', 'unknown', 'confidence', 0,
      'reason', 'low_quality_window', 'quality', v_f->'quality');
  END IF;

  -- personal baselines (spine first, then priors, then literals)
  v_base_rmssd := (v_f->>'baseline_rmssd')::numeric;
  IF v_base_rmssd IS NULL THEN
    SELECT mu INTO v_base_rmssd FROM public.personal_priors WHERE user_id=p_user AND param='hrv_baseline';
  END IF;
  v_base_rmssd := COALESCE(v_base_rmssd, 55);
  v_base_hr := (v_f->>'baseline_hr')::numeric;
  IF v_base_hr IS NULL THEN
    SELECT mu INTO v_base_hr FROM public.personal_priors WHERE user_id=p_user AND param='rhr_baseline';
  END IF;
  v_base_hr := COALESCE(v_base_hr, 58);

  -- normalized deviations
  v_rmssd_ratio := v_rmssd / NULLIF(v_base_rmssd,0);
  v_drop_pct := (1 - v_rmssd_ratio) * 100;          -- + = below baseline = aroused
  v_hr_rise  := v_hr - v_base_hr;                   -- + = above baseline = aroused
  v_a_rmssd  := v_drop_pct / NULLIF(v_drop_pct_thr,0);
  v_a_hr     := v_hr_rise  / NULLIF(v_hr_rise_thr,0);
  v_core     := (v_a_rmssd + v_a_hr) / 2.0;
  v_arousal  := GREATEST(0, LEAST(10, 5 + 2.5 * v_core));

  -- band + emoji
  v_band := CASE
    WHEN v_arousal < 2 THEN 'deep_calm'
    WHEN v_arousal < 4 THEN 'relaxed'
    WHEN v_arousal < 6 THEN 'neutral'
    WHEN v_arousal < 8 THEN 'elevated'
    ELSE 'high_arousal' END;
  v_emoji := CASE v_band
    WHEN 'deep_calm' THEN '😴' WHEN 'relaxed' THEN '🌊'
    WHEN 'neutral' THEN '⚪' WHEN 'elevated' THEN '⚡' ELSE '🔥' END;

  -- confidence: quality-led, penalized if the two core signals disagree strongly
  IF sign(v_a_rmssd) <> sign(v_a_hr) AND abs(v_a_rmssd) > 0.5 AND abs(v_a_hr) > 0.5 THEN
    v_disagree := true;
  END IF;
  v_conf := LEAST(1.0, GREATEST(0.0, v_qscore));
  IF v_disagree THEN v_conf := GREATEST(0.0, v_conf - 0.20); END IF;

  -- live Baevsky cross-check (only meaningful near now; null on historical replay)
  IF abs(EXTRACT(EPOCH FROM (now() - p_end))) < 600 THEN
    SELECT current_baevsky_stress, current_baevsky_stress_label
      INTO v_bv_val, v_bv_lbl FROM public.current_state WHERE user_id = p_user;
  END IF;

  -- light EMA smoothing (alpha 0.7 on new) if a recent prior read exists
  SELECT * INTO v_prev FROM public.biostate_state WHERE user_id=p_user AND detector='arousal';
  IF FOUND AND v_prev.committed_value IS NOT NULL
     AND v_prev.committed_at IS NOT NULL
     AND EXTRACT(EPOCH FROM (p_end - v_prev.committed_at)) BETWEEN 0 AND 900 THEN
    v_smoothed := round((0.3 * v_prev.committed_value + 0.7 * v_arousal)::numeric, 2);
  ELSE
    v_smoothed := round(v_arousal::numeric, 2);
  END IF;

  v_out := jsonb_build_object(
    'experimental', true,
    'detector', 'arousal',
    'ts', p_end,
    'window_s', v_win_s,
    'arousal', v_smoothed,
    'arousal_raw', round(v_arousal::numeric, 2),
    'band', v_band,
    'emoji', v_emoji,
    'confidence', round(v_conf::numeric, 2),
    'rmssd', round(v_rmssd::numeric, 1),
    'baseline_rmssd', round(v_base_rmssd::numeric, 1),
    'rmssd_drop_pct', round(v_drop_pct::numeric, 1),
    'hr', round(v_hr::numeric, 1),
    'baseline_hr', round(v_base_hr::numeric, 1),
    'hr_rise', round(v_hr_rise::numeric, 1),
    'a_rmssd', round(v_a_rmssd::numeric, 2),
    'a_hr', round(v_a_hr::numeric, 2),
    'signals_disagree', v_disagree,
    'sdnn', round(v_sdnn::numeric, 1),
    'lf_hf', CASE WHEN v_spec_ok THEN round(v_lf_hf::numeric, 2) ELSE NULL END,
    'lf_hf_note', CASE WHEN v_spec_ok THEN 'side_reading_not_in_score' ELSE 'spectral_low_quality' END,
    'dfa_alpha1', round(COALESCE(v_dfa,0)::numeric, 2),
    'baevsky_live', v_bv_val,
    'baevsky_live_label', v_bv_lbl,
    'sleep_stage', v_stage_lbl,
    'activity_state', v_act,
    'quality', v_f->'quality'
  );

  IF p_persist THEN
    INSERT INTO public.biostate_state
      (user_id, detector, updated_at, committed_stage, committed_value, committed_at,
       raw_stage, raw_since, confidence, experimental, payload)
    VALUES
      (p_user, 'arousal', now(), NULL, v_smoothed, p_end, NULL, p_end, v_conf, true, v_out)
    ON CONFLICT (user_id, detector) DO UPDATE SET
      updated_at      = now(),
      committed_value = EXCLUDED.committed_value,
      committed_at    = EXCLUDED.committed_at,
      confidence      = EXCLUDED.confidence,
      payload         = EXCLUDED.payload;
  END IF;

  RETURN v_out;
END $$;

GRANT EXECUTE ON FUNCTION public.arousal_now(uuid, timestamptz, boolean) TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.arousal_now(uuid, timestamptz, boolean) IS
  'EXPERIMENTAL biostate detector. Continuous arousal 0-10 (5=baseline) from time-domain HRV fusion (RMSSD drop % + HR rise vs personal baseline). LF/HF reported as side reading only (noisy on this data). Self-calibrates via state_truth_log. Output experimental:true — DO NOT consume as truth for mood/state.';
