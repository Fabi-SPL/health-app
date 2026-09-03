-- ════════════════════════════════════════════════════════════════════════════
--  v145 — biostate_all_now() combined read  +  learning quality-guard
--
--  1. biostate_all_now(): ONE call returns all three detectors — the iOS dashboard
--     makes a single round-trip instead of three.
--  2. log_state_correction quality-guard: a correction made during a NOISY window
--     (low coverage / motion artifact / disagreeing signals) still LOGS as training
--     data, but must NOT update the learned biostate_* priors — else an awake motion
--     artifact (e.g. RMSSD inflated to 176) would poison the calm baseline. Learning
--     only fires from clean windows.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. combined read ──────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.biostate_all_now(uuid, timestamptz, boolean);
CREATE OR REPLACE FUNCTION public.biostate_all_now(
  p_user    uuid        DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_end     timestamptz DEFAULT now(),
  p_persist boolean     DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN jsonb_build_object(
    'experimental', true,
    'ts', p_end,
    'arousal',     public.arousal_now(p_user, p_end, p_persist),
    'drunk',       public.drunk_now(p_user, p_end, p_persist),
    'respiration', public.respiration_now(p_user, p_end, p_persist)
  );
END $$;
GRANT EXECUTE ON FUNCTION public.biostate_all_now(uuid, timestamptz, boolean) TO anon, authenticated, service_role;
COMMENT ON FUNCTION public.biostate_all_now(uuid, timestamptz, boolean) IS
  'EXPERIMENTAL. One-call combined read of all three biostate detectors for the dashboard. experimental:true.';

-- ── 2. log_state_correction with learning quality-guard ───────────────────────
DROP FUNCTION IF EXISTS public.log_state_correction(text, text, numeric, text, uuid, timestamptz);
CREATE OR REPLACE FUNCTION public.log_state_correction(
  p_detector        text,
  p_corrected_state text        DEFAULT NULL,
  p_corrected_value numeric     DEFAULT NULL,
  p_note            text        DEFAULT NULL,
  p_user            uuid        DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_end             timestamptz DEFAULT now()
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_read jsonb; v_f jsonb; v_win int; v_det_state text; v_det_val numeric;
  v_rmssd numeric; v_hr numeric; v_bv numeric; v_id uuid; v_learned jsonb := '[]'::jsonb;
  v_q numeric; v_disagree boolean; v_learn_ok boolean; v_learn_note text := NULL;
BEGIN
  IF p_detector NOT IN ('vibe','arousal','respiration','drunk') THEN
    RETURN jsonb_build_object('error','bad_detector','detector',p_detector);
  END IF;

  IF    p_detector='drunk'       THEN v_read := public.drunk_now(p_user,p_end,false);
  ELSIF p_detector='arousal'     THEN v_read := public.arousal_now(p_user,p_end,false);
  ELSIF p_detector='respiration' THEN v_read := public.respiration_now(p_user,p_end,false);
  ELSE  v_read := '{}'::jsonb; END IF;

  v_win := COALESCE((SELECT (cfg#>>'{windows_s,arousal}')::int FROM public.biostate_config WHERE user_id=p_user),240);
  v_f := public.biostate_features_now(p_user,v_win,p_end);
  v_rmssd := (v_f->>'rmssd')::numeric; v_hr := (v_f->>'mean_hr')::numeric;
  v_q := (v_f#>>'{quality,score}')::numeric;
  v_disagree := COALESCE((v_read->>'signals_disagree')::boolean,false);

  IF    p_detector='drunk'       THEN v_det_state:=v_read->>'label'; v_det_val:=(v_read->>'stage')::numeric;
  ELSIF p_detector='arousal'     THEN v_det_state:=v_read->>'band';  v_det_val:=(v_read->>'arousal')::numeric;
  ELSIF p_detector='respiration' THEN v_det_state:=v_read->>'method';v_det_val:=(v_read->>'resp_rate')::numeric;
  END IF;

  IF abs(EXTRACT(EPOCH FROM (now()-p_end)))<600 THEN
    SELECT current_baevsky_stress INTO v_bv FROM public.current_state WHERE user_id=p_user;
  END IF;

  INSERT INTO public.state_truth_log(
    user_id, ts, detector, detected_state, detected_value, corrected_state, corrected_value,
    hr, rmssd, sdnn, pnn50, dfa_alpha1, lf_power, hf_power, lf_hf, total_power, lf_hf_hrc,
    resp_rate, baevsky_si, activity_state, motion_flag, feature_quality, baseline_rmssd, baseline_hr,
    note, source, experimental)
  VALUES(
    p_user, p_end, p_detector, v_det_state, v_det_val, p_corrected_state, p_corrected_value,
    v_hr, v_rmssd, (v_f->>'sdnn')::numeric, (v_f->>'pnn50')::numeric, (v_f->>'dfa_alpha1')::numeric,
    (v_f->>'lf')::numeric, (v_f->>'hf')::numeric, (v_f->>'lf_hf')::numeric, (v_f->>'total_power')::numeric,
    (v_f->>'lf_hf_hrc')::numeric, (v_f->>'resp_rate')::numeric, v_bv, v_f->>'activity_state',
    (COALESCE(v_f->>'activity_state','resting') <> 'resting'), v_q,
    (v_f->>'baseline_rmssd')::numeric, (v_f->>'baseline_hr')::numeric, p_note, 'manual', true)
  RETURNING id INTO v_id;

  -- learning quality-guard: only learn from CLEAN windows
  v_learn_ok := COALESCE(v_q,0) >= 0.7;
  IF NOT v_learn_ok THEN v_learn_note := 'window_too_noisy_logged_not_learned'; END IF;

  IF v_learn_ok AND p_detector='drunk' AND (p_corrected_value=0 OR lower(COALESCE(p_corrected_state,''))='sober')
       AND v_rmssd IS NOT NULL THEN
    PERFORM public.update_personal_prior(p_user,'biostate_sober_rmssd',v_rmssd,5.0);
    v_learned := v_learned || to_jsonb('biostate_sober_rmssd'::text);
  END IF;
  -- arousal: also require signals NOT disagreeing (disagree = artifact-inflated RMSSD)
  IF v_learn_ok AND NOT v_disagree AND p_detector='arousal'
       AND p_corrected_value IS NOT NULL AND p_corrected_value <= 4 AND v_rmssd IS NOT NULL THEN
    PERFORM public.update_personal_prior(p_user,'biostate_calm_rmssd',v_rmssd,5.0);
    IF v_hr IS NOT NULL THEN PERFORM public.update_personal_prior(p_user,'biostate_calm_hr',v_hr,3.0); END IF;
    v_learned := v_learned || to_jsonb('biostate_calm_rmssd'::text) || to_jsonb('biostate_calm_hr'::text);
  ELSIF p_detector='arousal' AND v_disagree AND v_learn_ok THEN
    v_learn_note := 'signals_disagreed_artifact_logged_not_learned';
  END IF;
  IF v_learn_ok AND p_detector='respiration' AND p_corrected_value IS NOT NULL THEN
    PERFORM public.update_personal_prior(p_user,'biostate_resp_baseline',p_corrected_value,2.0);
    v_learned := v_learned || to_jsonb('biostate_resp_baseline'::text);
  END IF;

  RETURN jsonb_build_object(
    'experimental', true, 'logged', true, 'truth_log_id', v_id, 'detector', p_detector, 'ts', p_end,
    'detected_state', v_det_state, 'detected_value', v_det_val,
    'corrected_state', p_corrected_state, 'corrected_value', p_corrected_value,
    'learned_priors', v_learned, 'learn_skipped_reason', v_learn_note,
    'window_quality', v_q,
    'snapshot', jsonb_build_object('rmssd',round(COALESCE(v_rmssd,0)::numeric,1),'hr',round(COALESCE(v_hr,0)::numeric,1))
  );
END $$;
GRANT EXECUTE ON FUNCTION public.log_state_correction(text,text,numeric,text,uuid,timestamptz) TO anon,authenticated,service_role;
