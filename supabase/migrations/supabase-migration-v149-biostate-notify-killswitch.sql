-- v149 — Per-detector NOTIFICATION KILL-SWITCH (arousal + respiration)
-- =============================================================================
-- WHY: the experimental BiostateNotifier (iOS) fires a lockscreen notification on every
--   detector STATE CHANGE (5-min throttle x 3 detectors). arousal (band flips) + respiration
--   (slow/normal/fast flips) generated ~300 notifications/day incl. overnight. The notifier has
--   NO server gate, and the app is a thin client (CLAUDE.md #7) — so the only no-build kill is
--   server-side: make the detector return a non-firing state.
--
-- WHAT: each detector now honors cfg.<detector>.enabled (default true). When false:
--   arousal_now -> band 'unknown' (notifier only fires on a real band) ; respiration_now ->
--   resp_rate NULL (notifier only fires when non-null). drunk_now is already gated by the
--   alcohol flag, so it stays silent unless drinking-mode is on.
--   Set 2026-06-22: cfg.arousal.enabled=false, cfg.respiration.enabled=false.
--   RE-ENABLE later: UPDATE biostate_config SET cfg=jsonb_set(cfg,'{arousal,enabled}','true') ...
--
-- SUPERSEDES arousal_now (was v147) + respiration_now (was v143) — those lack the kill-switch;
--   re-running them ALONE re-enables the notification storm. v149 is now canonical for both.
--   Idempotent (CREATE OR REPLACE + jsonb_set).
-- =============================================================================

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
  -- KILL SWITCH: cfg.arousal.enabled=false -> band 'unknown' so the lockscreen notifier stays silent
  -- (it only fires on a real band) and the dashboard shows "no read". Fully reversible (set enabled=true).
  IF COALESCE((v_ar->>'enabled')::boolean, true) = false THEN
    RETURN jsonb_build_object('experimental',true,'detector','arousal','ts',p_end,'arousal',NULL,
      'band','unknown','confidence',0,'reason','disabled_by_config');
  END IF;
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
END $function$;

CREATE OR REPLACE FUNCTION public.respiration_now(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, p_end timestamp with time zone DEFAULT now(), p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- KILL SWITCH: cfg.respiration.enabled=false -> resp_rate NULL so the lockscreen notifier stays
  -- silent (it only fires when resp_rate is non-null). Fully reversible (set enabled=true).
  IF COALESCE((v_rcfg->>'enabled')::boolean, true) = false THEN
    RETURN jsonb_build_object('experimental',true,'detector','respiration','ts',p_end,
      'resp_rate',NULL,'method','disabled','confidence',0,'reason','disabled_by_config');
  END IF;
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

  -- rolling median across recent raw estimates (kills residual bimodal jitter)
  v_smoothed := v_est;
  SELECT * INTO v_prev FROM public.biostate_state WHERE user_id=p_user AND detector='respiration';
  IF FOUND AND v_prev.payload ? 'recent_raw' THEN
    v_recent := v_prev.payload->'recent_raw';
  ELSE
    v_recent := '[]'::jsonb;
  END IF;
  v_arr := ARRAY(SELECT x::numeric FROM jsonb_array_elements_text(v_recent) x) || v_est;
  IF array_length(v_arr,1) > 5 THEN
    v_arr := v_arr[(array_length(v_arr,1)-4):array_length(v_arr,1)];
  END IF;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY u) INTO v_smoothed FROM unnest(v_arr) u;

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
END $function$;

-- flip both detectors OFF (silences the lockscreen notifier; dashboard shows "no read")
UPDATE public.biostate_config SET cfg =
  jsonb_set(jsonb_set(cfg,'{arousal,enabled}','false'::jsonb,true),'{respiration,enabled}','false'::jsonb,true)
  WHERE user_id='372210e5-1dda-41b3-b759-5ff72293b8ff';
