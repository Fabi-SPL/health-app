-- v234 rollback: puts back the v148 RMSSD-ladder drunk_now exactly as it ran before v234,
-- removes the heart-rate floor baseline, its refresh job and the hr_floor config, and restores
-- the 5-minute drinking-night sampler to its old flag_date condition.
BEGIN;

SELECT cron.unschedule('drunk_baseline_daily') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'drunk_baseline_daily');
SELECT cron.alter_job(34, command := $cmd$SELECT public.biostate_sample() WHERE EXISTS (SELECT 1 FROM public.alcohol_flags
    WHERE user_id='372210e5-1dda-41b3-b759-5ff72293b8ff' AND flag_date=(now() AT TIME ZONE 'Europe/Berlin')::date AND manual_drinking)$cmd$);

UPDATE public.biostate_config SET cfg = cfg #- '{drunk,hr_floor}'
 WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid;

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
  v_intensity numeric; v_hr_term numeric; v_r1 numeric; v_r2 numeric; v_r3 numeric; v_r4 numeric;
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
  -- CONTINUOUS 0-100 INTOXICATION (the smooth gradation Fabi wants; NO per-drink logging).
  -- Interpolate the RMSSD ratio across the stage thresholds (each stage band = 20 pts), nudge up
  -- for HR rise, clamp to the HR-gated committed stage (respects FIX6), then EMA-smooth the live bar.
  v_r1:=v_ratios[1]; v_r2:=v_ratios[2]; v_r3:=v_ratios[3]; v_r4:=v_ratios[4];
  v_intensity := CASE
    WHEN v_ratio >= 1.0  THEN 0
    WHEN v_ratio >= v_r1 THEN 20*(1.0 - v_ratio)/NULLIF(1.0 - v_r1,0)
    WHEN v_ratio >= v_r2 THEN 20 + 20*(v_r1 - v_ratio)/NULLIF(v_r1 - v_r2,0)
    WHEN v_ratio >= v_r3 THEN 40 + 20*(v_r2 - v_ratio)/NULLIF(v_r2 - v_r3,0)
    WHEN v_ratio >= v_r4 THEN 60 + 20*(v_r3 - v_ratio)/NULLIF(v_r3 - v_r4,0)
    WHEN v_ratio >= v_r4 - 0.10 THEN 80 + 20*(v_r4 - v_ratio)/NULLIF(0.10,0)
    ELSE 100 END;
  -- HR rise corroborates (and catches drunk-while-moving when motion inflates RMSSD), but HR alone
  -- with NO HRV suppression (biostage 0) must not imply much — half its weight there.
  v_hr_term := (CASE WHEN v_biostage >= 1 THEN 1.0 ELSE 0.5 END)
               * GREATEST(0, LEAST(1.0, v_hr_rise / NULLIF(v_alc_off,0)));
  v_intensity := 0.85*v_intensity + 12*v_hr_term;
  v_intensity := LEAST(v_intensity, v_committed*20 + 20);
  v_intensity := GREATEST(0, LEAST(100, v_intensity));
  IF v_prev.payload ? 'intensity' AND v_prev.committed_at IS NOT NULL
     AND EXTRACT(EPOCH FROM (p_end - v_prev.committed_at)) BETWEEN 0 AND 900 THEN
    v_intensity := round((0.4*(v_prev.payload->>'intensity')::numeric + 0.6*v_intensity)::numeric, 0);
  ELSE
    v_intensity := round(v_intensity::numeric, 0);
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
    'gated',false,'alcohol_mode',v_alc_on,'stage',v_committed,'intensity',v_intensity,'label',v_labels[v_committed+1],
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

DROP FUNCTION IF EXISTS public.refresh_drunk_baseline(uuid, int);
DROP FUNCTION IF EXISTS public.drunk_hr_floor(uuid, timestamptz, timestamptz);
DROP TABLE IF EXISTS public.drunk_floor_baseline;

COMMIT;
