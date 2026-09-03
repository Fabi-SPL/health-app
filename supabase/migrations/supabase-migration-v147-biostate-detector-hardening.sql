-- v147 — Biostate detector hardening (adversarial-audit follow-ups, 2026-06-18)
-- EXPERIMENTAL. Canonical post-fix definition of drunk_now + arousal_now.
-- ⚠️ v141 (drunk) / v142 (arousal) hold an OLDER, verbose, DIVERGENT implementation —
--    do NOT re-run them alone; they will clobber these. This file is the source of truth.
--
-- Audit verdict: arousal 34% trust, drunk 15%. Fixes applied + verified on live data:
--  drunk  #1 gate STRICTLY on manual alcohol_flags (default closed) — kills the
--             detect_overnight_alcohol() self-confirming loop (Jun-17 stage-4-while-asleep).
--         #6 stage>=2 (tipsy+) requires a real HR rise; nocturnal HRV dip alone caps at 1.
--         #4 confidence = quality x dip-decisiveness (no more hard-pinned ~1.0).
--  arousal#2 cap awake RMSSD ratio (motion artifacts 100-230ms no longer slam deep_calm 0).
--         #3 suppress band -> 'unknown' below conf floor (silences lockscreen spam + fake calm).
--         #4 discount confidence on near-baseline (low-information) reads.
--         #5 caffeine prior: within 90min of logged caffeine, weight HR over noisy RMSSD.

ALTER TABLE public.current_state ADD COLUMN IF NOT EXISTS current_baevsky_stress_label text;

UPDATE public.biostate_config SET cfg =
  jsonb_set(
    jsonb_set(cfg, '{drunk,conf_margin_full}', '0.10'::jsonb, true),
    '{arousal}',
    COALESCE(cfg->'arousal','{}'::jsonb) || '{"awake_rmssd_ratio_cap":1.3,"min_band_conf":0.55,"min_decisive_core":0.3}'::jsonb,
    true)
  WHERE user_id='372210e5-1dda-41b3-b759-5ff72293b8ff';

-- ============================== drunk_now ==============================
CREATE OR REPLACE FUNCTION public.drunk_now(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, p_end timestamp with time zone DEFAULT now(), p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cfg jsonb; v_dr jsonb; v_qcfg jsonb; v_win_s int; v_alc_on boolean; v_gated boolean;
  v_f jsonb; v_rmssd numeric; v_sdnn numeric; v_hr numeric; v_dfa numeric;
  v_qscore numeric; v_cov numeric; v_nbeats int; v_stage_lbl text; v_act text;
  v_base_rmssd numeric; v_base_hr numeric; v_alc_off numeric; v_ratios numeric[]; v_ratio numeric;
  v_biostage int; v_dfa_thresh numeric; v_dfa_fired boolean := false; v_hr_rise numeric; v_margin numeric; v_decis numeric;
  v_hr_corrob boolean := false; v_raw int; v_conf numeric; v_labels text[] := ARRAY['sober','buzzed','tipsy','drunk','wasted'];
  v_prev public.biostate_state%ROWTYPE; v_committed int; v_raw_since timestamptz; v_hold int; v_out jsonb;
BEGIN
  SELECT cfg INTO v_cfg FROM public.biostate_config WHERE user_id = p_user;
  v_dr := COALESCE(v_cfg->'drunk','{}'::jsonb); v_qcfg := COALESCE(v_cfg->'quality','{}'::jsonb);
  v_win_s := COALESCE((v_cfg#>>'{windows_s,drunk}')::int,180);
  v_gated := COALESCE((v_dr->>'gated_by_alcohol_mode')::boolean,true);
  -- FIX1: gate STRICTLY on Fabi's manual drinking flag for this Berlin date; default CLOSED.
  -- (was is_alcohol_mode(), which falls back to detect_overnight_alcohol() — that auto-detector
  --  fires on the SAME noisy overnight HRV the ladder below reads, a self-confirming false-positive
  --  loop. Jun-17 stage-4-while-asleep came from exactly this. Manual flag is the only ground truth.)
  SELECT COALESCE(bool_or(manual_drinking),false) INTO v_alc_on
    FROM public.alcohol_flags
    WHERE user_id=p_user AND flag_date=(p_end AT TIME ZONE 'Europe/Berlin')::date;
  v_alc_on := COALESCE(v_alc_on,false);
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
  v_hr_rise := v_hr - v_base_hr;
  IF v_hr_rise >= 0.4*v_alc_off THEN v_hr_corrob:=true; END IF;
  -- FIX6: tipsy+ (stage>=2) requires a real HR elevation; a nocturnal HRV dip alone must not reach it.
  IF v_biostage >= 2 AND v_hr_rise < COALESCE((v_dr->>'stage2_min_hr_rise')::numeric, v_alc_off) THEN
    v_biostage := 1;
  END IF;
  v_raw := v_biostage;
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
  -- FIX4: confidence = signal quality x dip decisiveness (distance of the ratio from the nearest
  -- stage boundary). A marginal dip sitting on a threshold can no longer report ~1.0.
  v_margin := LEAST(abs(v_ratio-v_ratios[1]),abs(v_ratio-v_ratios[2]),abs(v_ratio-v_ratios[3]),abs(v_ratio-v_ratios[4]));
  v_decis := LEAST(1.0, v_margin / COALESCE((v_dr->>'conf_margin_full')::numeric,0.10));
  v_conf := LEAST(1.0,GREATEST(0.0,v_qscore)) * (0.4 + 0.6*v_decis);
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
END $function$
;
GRANT EXECUTE ON FUNCTION public.drunk_now(uuid, timestamptz, boolean) TO anon, authenticated, service_role;

-- ============================== arousal_now ==============================
CREATE OR REPLACE FUNCTION public.arousal_now(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, p_end timestamp with time zone DEFAULT now(), p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cfg jsonb; v_ar jsonb; v_qcfg jsonb; v_win_s int; v_f jsonb;
  v_rmssd numeric; v_hr numeric; v_sdnn numeric; v_lf_hf numeric; v_dfa numeric;
  v_qscore numeric; v_cov numeric; v_nbeats int; v_spec_ok boolean; v_stage_lbl text; v_act text;
  v_base_rmssd numeric; v_base_hr numeric; v_drop_pct_thr numeric; v_hr_rise_thr numeric;
  v_rmssd_ratio numeric; v_drop_pct numeric; v_hr_rise numeric; v_a_rmssd numeric; v_a_hr numeric;
  v_core numeric; v_arousal numeric; v_band text; v_emoji text; v_conf numeric; v_disagree boolean:=false;
  v_bv_val numeric; v_bv_lbl text; v_prev public.biostate_state%ROWTYPE; v_smoothed numeric; v_out jsonb; v_caffeine boolean := false;
BEGIN
  SELECT cfg INTO v_cfg FROM public.biostate_config WHERE user_id=p_user;
  v_ar:=COALESCE(v_cfg->'arousal','{}'::jsonb); v_qcfg:=COALESCE(v_cfg->'quality','{}'::jsonb);
  v_win_s:=COALESCE((v_cfg#>>'{windows_s,arousal}')::int,240);
  v_drop_pct_thr:=COALESCE((v_ar->>'stress_rmssd_drop_pct')::numeric,20);
  v_hr_rise_thr:=COALESCE((v_ar->>'stress_hr_rise_bpm')::numeric,10);
  v_f:=public.biostate_features_now(p_user,v_win_s,p_end);
  v_rmssd:=(v_f->>'rmssd')::numeric; v_hr:=(v_f->>'mean_hr')::numeric; v_sdnn:=(v_f->>'sdnn')::numeric;
  v_lf_hf:=(v_f->>'lf_hf')::numeric; v_dfa:=(v_f->>'dfa_alpha1')::numeric;
  v_qscore:=(v_f#>>'{quality,score}')::numeric; v_cov:=(v_f#>>'{quality,coverage_frac}')::numeric; v_nbeats:=(v_f#>>'{quality,n_beats}')::int;
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
  -- FIX2: awake motion artifacts inflate RMSSD (100-230ms) and slam arousal to a fake deep_calm 0.
  -- While awake, cap the ratio so one noisy window can't read "deeper than calm".
  IF COALESCE(v_stage_lbl,'awake') NOT IN ('light','deep','rem','sleep','asleep') THEN
    v_rmssd_ratio:=LEAST(v_rmssd_ratio, COALESCE((v_ar->>'awake_rmssd_ratio_cap')::numeric,1.3));
  END IF;
  v_drop_pct:=(1-v_rmssd_ratio)*100; v_hr_rise:=v_hr-v_base_hr;
  v_a_rmssd:=v_drop_pct/NULLIF(v_drop_pct_thr,0); v_a_hr:=v_hr_rise/NULLIF(v_hr_rise_thr,0);
  -- FIX5: within 90min of a logged caffeine intake, expect a rise — trust HR over the motion-noisy
  -- RMSSD term (weight 0.7/0.3 instead of 0.5/0.5).
  SELECT count(*)>0 INTO v_caffeine FROM public.food_entries
    WHERE user_id=p_user AND captured_at BETWEEN p_end - interval '90 minutes' AND p_end
      AND caption ~* 'espresso|coffee|kaffee|caffeine|koffein|mate|energy drink|cola|red ?bull';
  IF v_caffeine THEN v_core:=0.3*v_a_rmssd+0.7*v_a_hr;
  ELSE v_core:=(v_a_rmssd+v_a_hr)/2.0; END IF;
  v_arousal:=GREATEST(0,LEAST(10,5+2.5*v_core));
  v_band:=CASE WHEN v_arousal<2 THEN 'deep_calm' WHEN v_arousal<4 THEN 'relaxed'
    WHEN v_arousal<6 THEN 'neutral' WHEN v_arousal<8 THEN 'elevated' ELSE 'high_arousal' END;
  v_emoji:=CASE v_band WHEN 'deep_calm' THEN '😴' WHEN 'relaxed' THEN '🌊' WHEN 'neutral' THEN '⚪'
    WHEN 'elevated' THEN '⚡' ELSE '🔥' END;
  IF sign(v_a_rmssd)<>sign(v_a_hr) AND abs(v_a_rmssd)>0.5 AND abs(v_a_hr)>0.5 THEN v_disagree:=true; END IF;
  v_conf:=LEAST(1.0,GREATEST(0.0,v_qscore)); IF v_disagree THEN v_conf:=GREATEST(0.0,v_conf-0.20); END IF;
  -- FIX4: a near-baseline reading carries little information — don't report it as confident.
  IF abs(v_core) < COALESCE((v_ar->>'min_decisive_core')::numeric,0.3) THEN v_conf:=v_conf*0.7; END IF;
  -- FIX3: below the band-confidence floor, emit band 'unknown' so the lockscreen notifier stays
  -- silent (it only fires on real bands) and the dashboard shows "no read" instead of a fake calm.
  IF v_conf < COALESCE((v_ar->>'min_band_conf')::numeric,0.55) THEN
    v_band:='unknown'; v_emoji:='❔';
  END IF;
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
END $function$
;
GRANT EXECUTE ON FUNCTION public.arousal_now(uuid, timestamptz, boolean) TO anon, authenticated, service_role;
