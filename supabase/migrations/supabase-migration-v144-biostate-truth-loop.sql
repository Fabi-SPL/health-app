-- ════════════════════════════════════════════════════════════════════════════
--  v144 — Biostate TRUTH LOOP  (EXPERIMENTAL, the learning circle)
--
--  Fabi corrects a wrong read → log_state_correction():
--    1. re-runs the detector at that moment to capture what the model SAID + the
--       full biometric feature snapshot (the training X),
--    2. writes a state_truth_log row (detected vs corrected + snapshot, experimental),
--    3. LEARNS by Bayesian-updating NAMESPACED experimental priors (biostate_*),
--       never the shared hrv_baseline/rhr_baseline that production reads — so an
--       experimental correction can NEVER pollute real sleep/alcohol calculations.
--
--  drunk_now + arousal_now are re-created here to PREFER the learned biostate_*
--  anchors (fallback to shared prior → literal), which actually closes the loop:
--  a correction changes future reads. respiration learns biostate_resp_baseline
--  (kept for future use; respiration_now already self-smooths).
--
--  Learned params (all experimental, isolated):
--    biostate_sober_rmssd  — confirmed-sober RMSSD → drunk ladder anchor
--    biostate_calm_rmssd   — confirmed-calm RMSSD  → arousal RMSSD baseline
--    biostate_calm_hr      — confirmed-calm HR     → arousal HR baseline
--    biostate_resp_baseline— confirmed breathing rate
-- ════════════════════════════════════════════════════════════════════════════

-- rebuild-safety: the live-baevsky label column arousal_now reads must exist
ALTER TABLE public.current_state ADD COLUMN IF NOT EXISTS current_baevsky_stress_label text;

-- ── re-create drunk_now: prefer learned biostate_sober_rmssd ──────────────────
DROP FUNCTION IF EXISTS public.drunk_now(uuid, timestamptz, boolean);
CREATE OR REPLACE FUNCTION public.drunk_now(
  p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_end timestamptz DEFAULT now(), p_persist boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg jsonb; v_dr jsonb; v_qcfg jsonb; v_win_s int; v_alc_on boolean; v_gated boolean;
  v_f jsonb; v_rmssd numeric; v_sdnn numeric; v_hr numeric; v_dfa numeric;
  v_qscore numeric; v_cov numeric; v_nbeats int; v_stage_lbl text; v_act text;
  v_base_rmssd numeric; v_base_hr numeric; v_alc_off numeric; v_ratios numeric[]; v_ratio numeric;
  v_biostage int; v_dfa_thresh numeric; v_dfa_fired boolean := false; v_hr_rise numeric;
  v_hr_corrob boolean := false; v_raw int; v_conf numeric; v_labels text[] := ARRAY['sober','buzzed','tipsy','drunk','wasted'];
  v_prev public.biostate_state%ROWTYPE; v_committed int; v_raw_since timestamptz; v_hold int; v_out jsonb;
BEGIN
  SELECT cfg INTO v_cfg FROM public.biostate_config WHERE user_id = p_user;
  v_dr := COALESCE(v_cfg->'drunk','{}'::jsonb); v_qcfg := COALESCE(v_cfg->'quality','{}'::jsonb);
  v_win_s := COALESCE((v_cfg#>>'{windows_s,drunk}')::int,180);
  v_gated := COALESCE((v_dr->>'gated_by_alcohol_mode')::boolean,true);
  v_alc_on := COALESCE(public.is_alcohol_mode(p_user,(p_end AT TIME ZONE 'Europe/Berlin')::date),false);
  IF v_gated AND NOT v_alc_on THEN
    RETURN jsonb_build_object('experimental',true,'detector','drunk','ts',p_end,'gated',true,
      'alcohol_mode',false,'stage',0,'label','sober','confidence',1.0,'reason','alcohol_mode_off_forced_sober');
  END IF;
  v_f := public.biostate_features_now(p_user,v_win_s,p_end);
  v_rmssd:=(v_f->>'rmssd')::numeric; v_sdnn:=(v_f->>'sdnn')::numeric; v_hr:=(v_f->>'mean_hr')::numeric;
  v_dfa:=(v_f->>'dfa_alpha1')::numeric; v_qscore:=(v_f#>>'{quality,score}')::numeric;
  v_cov:=(v_f#>>'{quality,coverage_frac}')::numeric; v_nbeats:=(v_f#>>'{quality,n_beats}')::int;
  v_stage_lbl:=v_f->>'sleep_stage'; v_act:=v_f->>'activity_state';
  IF v_rmssd IS NULL OR v_qscore IS NULL
     OR v_qscore < COALESCE((v_qcfg->>'min_quality_score')::numeric,0.4)
     OR COALESCE(v_cov,0) < COALESCE((v_qcfg->>'min_coverage_frac')::numeric,0.4)
     OR COALESCE(v_nbeats,0) < COALESCE((v_qcfg->>'min_beats')::int,20) THEN
    RETURN jsonb_build_object('experimental',true,'detector','drunk','ts',p_end,'gated',false,
      'alcohol_mode',v_alc_on,'stage',NULL,'label','unknown','confidence',0,'reason','low_quality_window',
      'quality',v_f->'quality','rmssd',round(COALESCE(v_rmssd,0)::numeric,1));
  END IF;
  -- LEARNED anchor first, then shared prior, then cfg fallback
  SELECT mu INTO v_base_rmssd FROM public.personal_priors WHERE user_id=p_user AND param='biostate_sober_rmssd';
  IF v_base_rmssd IS NULL THEN SELECT mu INTO v_base_rmssd FROM public.personal_priors WHERE user_id=p_user AND param='hrv_baseline'; END IF;
  v_base_rmssd := COALESCE(v_base_rmssd,(v_dr->>'sober_rmssd_fallback')::numeric,55);
  SELECT mu INTO v_base_hr FROM public.personal_priors WHERE user_id=p_user AND param='rhr_baseline';
  v_base_hr := COALESCE(v_base_hr,51);
  SELECT mu INTO v_alc_off FROM public.personal_priors WHERE user_id=p_user AND param='alcohol_hr_offset';
  v_alc_off := COALESCE(v_alc_off,10);
  v_ratios := ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_dr->'rmssd_ratios','[0.91,0.82,0.64,0.55]'::jsonb))::numeric);
  v_ratio := v_rmssd / NULLIF(v_base_rmssd,0);
  v_biostage := CASE WHEN v_ratio>=v_ratios[1] THEN 0 WHEN v_ratio>=v_ratios[2] THEN 1
    WHEN v_ratio>=v_ratios[3] THEN 2 WHEN v_ratio>=v_ratios[4] THEN 3 ELSE 4 END;
  v_dfa_thresh := COALESCE((v_dr->>'dfa_alpha1_alcohol_thresh')::numeric,0.75);
  IF v_dfa IS NOT NULL AND v_dfa>0.1 AND v_dfa<v_dfa_thresh AND v_biostage>=1 THEN
    v_dfa_fired:=true; v_biostage:=LEAST(v_biostage+1,4); END IF;
  v_raw := v_biostage;
  v_hr_rise := v_hr - v_base_hr;
  IF v_hr_rise >= 0.4*v_alc_off THEN v_hr_corrob:=true; END IF;
  SELECT * INTO v_prev FROM public.biostate_state WHERE user_id=p_user AND detector='drunk';
  IF NOT FOUND OR v_prev.committed_stage IS NULL THEN v_committed:=v_raw; v_raw_since:=p_end;
  ELSE
    IF v_prev.raw_stage IS DISTINCT FROM v_raw THEN v_raw_since:=p_end; ELSE v_raw_since:=COALESCE(v_prev.raw_since,p_end); END IF;
    v_hold := CASE WHEN v_raw>v_prev.committed_stage THEN COALESCE((v_dr#>>'{hysteresis_s,rise_hold}')::int,45)
                   ELSE COALESCE((v_dr#>>'{hysteresis_s,fall_hold}')::int,150) END;
    IF v_raw=v_prev.committed_stage THEN v_committed:=v_prev.committed_stage;
    ELSIF EXTRACT(EPOCH FROM (p_end-v_raw_since))>=v_hold THEN v_committed:=v_raw;
    ELSE v_committed:=v_prev.committed_stage; END IF;
  END IF;
  v_conf := LEAST(1.0,GREATEST(0.0,v_qscore));
  IF v_committed>=2 AND v_hr_corrob THEN v_conf:=LEAST(1.0,v_conf+0.10); END IF;
  IF v_dfa_fired THEN v_conf:=LEAST(1.0,v_conf+0.05); END IF;
  IF v_committed>=3 AND NOT v_hr_corrob THEN v_conf:=GREATEST(0.0,v_conf-0.10); END IF;
  v_out := jsonb_build_object('experimental',true,'detector','drunk','ts',p_end,'window_s',v_win_s,
    'gated',false,'alcohol_mode',v_alc_on,'stage',v_committed,'label',v_labels[v_committed+1],
    'raw_stage',v_raw,'raw_label',v_labels[v_raw+1],'confidence',round(v_conf::numeric,2),
    'rmssd',round(v_rmssd::numeric,1),'baseline_rmssd',round(v_base_rmssd::numeric,1),
    'rmssd_ratio',round(v_ratio::numeric,3),'sdnn',round(v_sdnn::numeric,1),'hr',round(v_hr::numeric,1),
    'baseline_hr',round(v_base_hr::numeric,1),'hr_rise',round(v_hr_rise::numeric,1),'hr_corroborated',v_hr_corrob,
    'dfa_alpha1',round(COALESCE(v_dfa,0)::numeric,2),'dfa_booster_fired',v_dfa_fired,
    'sleep_stage',v_stage_lbl,'activity_state',v_act,'quality',v_f->'quality');
  IF p_persist THEN
    INSERT INTO public.biostate_state(user_id,detector,updated_at,committed_stage,committed_value,committed_at,raw_stage,raw_since,confidence,experimental,payload)
    VALUES(p_user,'drunk',now(),v_committed,v_ratio,p_end,v_raw,v_raw_since,v_conf,true,v_out)
    ON CONFLICT (user_id,detector) DO UPDATE SET updated_at=now(),committed_stage=EXCLUDED.committed_stage,
      committed_value=EXCLUDED.committed_value,committed_at=EXCLUDED.committed_at,raw_stage=EXCLUDED.raw_stage,
      raw_since=EXCLUDED.raw_since,confidence=EXCLUDED.confidence,payload=EXCLUDED.payload;
  END IF;
  RETURN v_out;
END $$;
GRANT EXECUTE ON FUNCTION public.drunk_now(uuid,timestamptz,boolean) TO anon,authenticated,service_role;

-- ── re-create arousal_now: prefer learned biostate_calm_rmssd / biostate_calm_hr ──
DROP FUNCTION IF EXISTS public.arousal_now(uuid, timestamptz, boolean);
CREATE OR REPLACE FUNCTION public.arousal_now(
  p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_end timestamptz DEFAULT now(), p_persist boolean DEFAULT true
) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg jsonb; v_ar jsonb; v_qcfg jsonb; v_win_s int; v_f jsonb;
  v_rmssd numeric; v_hr numeric; v_sdnn numeric; v_lf_hf numeric; v_dfa numeric;
  v_qscore numeric; v_cov numeric; v_nbeats int; v_spec_ok boolean; v_stage_lbl text; v_act text;
  v_base_rmssd numeric; v_base_hr numeric; v_drop_pct_thr numeric; v_hr_rise_thr numeric;
  v_rmssd_ratio numeric; v_drop_pct numeric; v_hr_rise numeric; v_a_rmssd numeric; v_a_hr numeric;
  v_core numeric; v_arousal numeric; v_band text; v_emoji text; v_conf numeric; v_disagree boolean:=false;
  v_bv_val numeric; v_bv_lbl text; v_prev public.biostate_state%ROWTYPE; v_smoothed numeric; v_out jsonb;
BEGIN
  SELECT cfg INTO v_cfg FROM public.biostate_config WHERE user_id=p_user;
  v_ar:=COALESCE(v_cfg->'arousal','{}'::jsonb); v_qcfg:=COALESCE(v_cfg->'quality','{}'::jsonb);
  v_win_s:=COALESCE((v_cfg#>>'{windows_s,arousal}')::int,240);
  v_drop_pct_thr:=COALESCE((v_ar->>'stress_rmssd_drop_pct')::numeric,20);
  v_hr_rise_thr:=COALESCE((v_ar->>'stress_hr_rise_bpm')::numeric,10);
  v_f:=public.biostate_features_now(p_user,v_win_s,p_end);
  v_rmssd:=(v_f->>'rmssd')::numeric; v_hr:=(v_f->>'mean_hr')::numeric; v_sdnn:=(v_f->>'sdnn')::numeric;
  v_lf_hf:=(v_f->>'lf_hf')::numeric; v_dfa:=(v_f->>'dfa_alpha1')::numeric;
  v_qscore:=(v_f#>>'{quality,score}')::numeric; v_cov:=(v_f#>>'{quality,coverage_frac}')::numeric;
  v_nbeats:=(v_f#>>'{quality,n_beats}')::int;
  v_spec_ok:=(v_f#>>'{quality,spectral_ok}')::boolean; v_stage_lbl:=v_f->>'sleep_stage'; v_act:=v_f->>'activity_state';
  IF v_rmssd IS NULL OR v_hr IS NULL OR v_qscore IS NULL
     OR v_qscore < COALESCE((v_qcfg->>'min_quality_score')::numeric,0.4)
     OR COALESCE(v_cov,0) < COALESCE((v_qcfg->>'min_coverage_frac')::numeric,0.4)
     OR COALESCE(v_nbeats,0) < COALESCE((v_qcfg->>'min_beats')::int,20) THEN
    RETURN jsonb_build_object('experimental',true,'detector','arousal','ts',p_end,'arousal',NULL,
      'band','unknown','confidence',0,'reason','low_quality_window','quality',v_f->'quality');
  END IF;
  -- LEARNED calm anchors first, then spine baseline, then shared prior, then literal
  SELECT mu INTO v_base_rmssd FROM public.personal_priors WHERE user_id=p_user AND param='biostate_calm_rmssd';
  v_base_rmssd := COALESCE(v_base_rmssd,(v_f->>'baseline_rmssd')::numeric,
                    (SELECT mu FROM public.personal_priors WHERE user_id=p_user AND param='hrv_baseline'),55);
  SELECT mu INTO v_base_hr FROM public.personal_priors WHERE user_id=p_user AND param='biostate_calm_hr';
  v_base_hr := COALESCE(v_base_hr,(v_f->>'baseline_hr')::numeric,
                    (SELECT mu FROM public.personal_priors WHERE user_id=p_user AND param='rhr_baseline'),58);
  v_rmssd_ratio:=v_rmssd/NULLIF(v_base_rmssd,0);
  v_drop_pct:=(1-v_rmssd_ratio)*100; v_hr_rise:=v_hr-v_base_hr;
  v_a_rmssd:=v_drop_pct/NULLIF(v_drop_pct_thr,0); v_a_hr:=v_hr_rise/NULLIF(v_hr_rise_thr,0);
  v_core:=(v_a_rmssd+v_a_hr)/2.0; v_arousal:=GREATEST(0,LEAST(10,5+2.5*v_core));
  v_band:=CASE WHEN v_arousal<2 THEN 'deep_calm' WHEN v_arousal<4 THEN 'relaxed'
    WHEN v_arousal<6 THEN 'neutral' WHEN v_arousal<8 THEN 'elevated' ELSE 'high_arousal' END;
  v_emoji:=CASE v_band WHEN 'deep_calm' THEN '😴' WHEN 'relaxed' THEN '🌊' WHEN 'neutral' THEN '⚪'
    WHEN 'elevated' THEN '⚡' ELSE '🔥' END;
  IF sign(v_a_rmssd)<>sign(v_a_hr) AND abs(v_a_rmssd)>0.5 AND abs(v_a_hr)>0.5 THEN v_disagree:=true; END IF;
  v_conf:=LEAST(1.0,GREATEST(0.0,v_qscore)); IF v_disagree THEN v_conf:=GREATEST(0.0,v_conf-0.20); END IF;
  IF abs(EXTRACT(EPOCH FROM (now()-p_end)))<600 THEN
    SELECT current_baevsky_stress,current_baevsky_stress_label INTO v_bv_val,v_bv_lbl FROM public.current_state WHERE user_id=p_user;
  END IF;
  SELECT * INTO v_prev FROM public.biostate_state WHERE user_id=p_user AND detector='arousal';
  IF FOUND AND v_prev.committed_value IS NOT NULL AND v_prev.committed_at IS NOT NULL
     AND EXTRACT(EPOCH FROM (p_end-v_prev.committed_at)) BETWEEN 0 AND 900 THEN
    v_smoothed:=round((0.3*v_prev.committed_value+0.7*v_arousal)::numeric,2);
  ELSE v_smoothed:=round(v_arousal::numeric,2); END IF;
  v_out:=jsonb_build_object('experimental',true,'detector','arousal','ts',p_end,'window_s',v_win_s,
    'arousal',v_smoothed,'arousal_raw',round(v_arousal::numeric,2),'band',v_band,'emoji',v_emoji,
    'confidence',round(v_conf::numeric,2),'rmssd',round(v_rmssd::numeric,1),'baseline_rmssd',round(v_base_rmssd::numeric,1),
    'rmssd_drop_pct',round(v_drop_pct::numeric,1),'hr',round(v_hr::numeric,1),'baseline_hr',round(v_base_hr::numeric,1),
    'hr_rise',round(v_hr_rise::numeric,1),'a_rmssd',round(v_a_rmssd::numeric,2),'a_hr',round(v_a_hr::numeric,2),
    'signals_disagree',v_disagree,'sdnn',round(v_sdnn::numeric,1),
    'lf_hf',CASE WHEN v_spec_ok THEN round(v_lf_hf::numeric,2) ELSE NULL END,
    'dfa_alpha1',round(COALESCE(v_dfa,0)::numeric,2),'baevsky_live',v_bv_val,'baevsky_live_label',v_bv_lbl,
    'sleep_stage',v_stage_lbl,'activity_state',v_act,'quality',v_f->'quality');
  IF p_persist THEN
    INSERT INTO public.biostate_state(user_id,detector,updated_at,committed_stage,committed_value,committed_at,raw_stage,raw_since,confidence,experimental,payload)
    VALUES(p_user,'arousal',now(),NULL,v_smoothed,p_end,NULL,p_end,v_conf,true,v_out)
    ON CONFLICT (user_id,detector) DO UPDATE SET updated_at=now(),committed_value=EXCLUDED.committed_value,
      committed_at=EXCLUDED.committed_at,confidence=EXCLUDED.confidence,payload=EXCLUDED.payload;
  END IF;
  RETURN v_out;
END $$;
GRANT EXECUTE ON FUNCTION public.arousal_now(uuid,timestamptz,boolean) TO anon,authenticated,service_role;

-- ── log_state_correction: the learning entry point ────────────────────────────
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
BEGIN
  IF p_detector NOT IN ('vibe','arousal','respiration','drunk') THEN
    RETURN jsonb_build_object('error','bad_detector','detector',p_detector);
  END IF;

  -- run the detector to capture what it SAID (no persist — this is a labeling read)
  IF    p_detector='drunk'       THEN v_read := public.drunk_now(p_user,p_end,false);
  ELSIF p_detector='arousal'     THEN v_read := public.arousal_now(p_user,p_end,false);
  ELSIF p_detector='respiration' THEN v_read := public.respiration_now(p_user,p_end,false);
  ELSE  v_read := '{}'::jsonb; END IF;

  -- rich feature snapshot (arousal window = widest)
  v_win := COALESCE((SELECT (cfg#>>'{windows_s,arousal}')::int FROM public.biostate_config WHERE user_id=p_user),240);
  v_f := public.biostate_features_now(p_user,v_win,p_end);
  v_rmssd := (v_f->>'rmssd')::numeric; v_hr := (v_f->>'mean_hr')::numeric;

  -- detected_* per detector
  IF    p_detector='drunk'       THEN v_det_state:=v_read->>'label'; v_det_val:=(v_read->>'stage')::numeric;
  ELSIF p_detector='arousal'     THEN v_det_state:=v_read->>'band';  v_det_val:=(v_read->>'arousal')::numeric;
  ELSIF p_detector='respiration' THEN v_det_state:=v_read->>'method';v_det_val:=(v_read->>'resp_rate')::numeric;
  END IF;

  -- live baevsky for the snapshot if near now
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
    (COALESCE(v_f->>'activity_state','resting') <> 'resting'), (v_f#>>'{quality,score}')::numeric,
    (v_f->>'baseline_rmssd')::numeric, (v_f->>'baseline_hr')::numeric, p_note, 'manual', true)
  RETURNING id INTO v_id;

  -- LEARN into namespaced experimental priors only (never shared hrv/rhr)
  IF p_detector='drunk' AND (p_corrected_value=0 OR lower(COALESCE(p_corrected_state,''))='sober')
       AND v_rmssd IS NOT NULL THEN
    PERFORM public.update_personal_prior(p_user,'biostate_sober_rmssd',v_rmssd,5.0);
    v_learned := v_learned || to_jsonb('biostate_sober_rmssd'::text);
  END IF;
  IF p_detector='arousal' AND p_corrected_value IS NOT NULL AND p_corrected_value <= 4
       AND v_rmssd IS NOT NULL THEN
    PERFORM public.update_personal_prior(p_user,'biostate_calm_rmssd',v_rmssd,5.0);
    IF v_hr IS NOT NULL THEN PERFORM public.update_personal_prior(p_user,'biostate_calm_hr',v_hr,3.0); END IF;
    v_learned := v_learned || to_jsonb('biostate_calm_rmssd'::text) || to_jsonb('biostate_calm_hr'::text);
  END IF;
  IF p_detector='respiration' AND p_corrected_value IS NOT NULL THEN
    PERFORM public.update_personal_prior(p_user,'biostate_resp_baseline',p_corrected_value,2.0);
    v_learned := v_learned || to_jsonb('biostate_resp_baseline'::text);
  END IF;

  RETURN jsonb_build_object(
    'experimental', true, 'logged', true, 'truth_log_id', v_id, 'detector', p_detector, 'ts', p_end,
    'detected_state', v_det_state, 'detected_value', v_det_val,
    'corrected_state', p_corrected_state, 'corrected_value', p_corrected_value,
    'learned_priors', v_learned,
    'snapshot', jsonb_build_object('rmssd',round(COALESCE(v_rmssd,0)::numeric,1),'hr',round(COALESCE(v_hr,0)::numeric,1),
                  'quality',(v_f#>>'{quality,score}'))
  );
END $$;
GRANT EXECUTE ON FUNCTION public.log_state_correction(text,text,numeric,text,uuid,timestamptz) TO anon,authenticated,service_role;

COMMENT ON FUNCTION public.log_state_correction(text,text,numeric,text,uuid,timestamptz) IS
  'EXPERIMENTAL truth loop. Logs a detected-vs-corrected row + biometric snapshot to state_truth_log and Bayesian-updates NAMESPACED biostate_* priors (never shared hrv/rhr baselines). This is how Fabi teaches the detectors. experimental:true.';
