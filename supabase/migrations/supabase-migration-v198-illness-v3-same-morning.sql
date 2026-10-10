-- v198: illness detection stops reading empty nights as healthy, and scores the same morning.
-- illness_cusum_ensemble (v3, same signature): a night without RHR/HRV is NULL, not green (09-30..10-06
--   all read green/0.4); sums reset after 3 empty nights; 10 baseline nights minimum; alcohol nights count
--   zero; skin temp only mandatory while its robust SD <= 0.5 C; resp only inside 10-24; a partial night
--   (sleep_complete = false) counts as missing, in the input and in health_signal_baseline. Both RHR
--   episodes of July (07-04, 07-25) started on a 61-66% observed night whose RHR read far above baseline.
-- illness_risk_now: the CuSum tier now reaches the Today card (a slow multi-night drift could not before).
-- crons: illness scored 06:00 and 10:00 UTC for today; recompute_health_metrics for today at 09:55 UTC.
-- body_battery_at: body_battery_now with the clock as a parameter (used to replay 09-20..10-07).
-- Rollback: supabase-migration-v198-rollback.sql

CREATE OR REPLACE FUNCTION public.illness_cusum_ensemble(p_user_id uuid, p_date date)
 RETURNS TABLE(tier text, score numeric, signals jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  k numeric := 0.8; h numeric := 5.0;
  min_n constant int := 10;
  gap_reset constant int := 3;
  skin_max_rsd constant numeric := 0.5;
  d date; row_hm record; bl record; z numeric;
  s_rhr numeric:=0; s_rmssd numeric:=0; s_resp numeric:=0; s_pnn numeric:=0; s_skin numeric:=0;
  p_rhr int:=0; p_rmssd int:=0; p_skin int:=0;
  a_rhr boolean:=false; a_rmssd boolean:=false; a_resp boolean:=false; a_pnn boolean:=false; a_skin boolean:=false;
  skin_mand boolean:=false; is_alc boolean; gap int:=0; last_present boolean:=false;
  mand_alarms int; mand_persist int; bonus_alarms int; n_eps int;
  v_tier text; v_score numeric; v_sig jsonb; v_note text;
BEGIN
  FOR d IN SELECT generate_series(p_date - 15, p_date, '1 day')::date LOOP
    SELECT resting_hr, hrv_avg, respiratory_rate, pnn50_avg, skin_temp, COALESCE(alcohol_impact,0) AS alc
      INTO row_hm FROM health_metrics
     WHERE user_id=p_user_id AND metric_date=d AND COALESCE(excluded,false)=false
       AND sleep_complete IS NOT FALSE;

    last_present := FOUND AND (COALESCE(row_hm.resting_hr,0) > 0 OR COALESCE(row_hm.hrv_avg,0) > 0);
    IF NOT last_present THEN
      gap := gap + 1;
      IF gap >= gap_reset THEN
        s_rhr:=0; s_rmssd:=0; s_resp:=0; s_pnn:=0; s_skin:=0; p_rhr:=0; p_rmssd:=0; p_skin:=0;
      END IF;
      CONTINUE;
    END IF;
    gap := 0;

    a_rhr:=false; a_rmssd:=false; a_resp:=false; a_pnn:=false; a_skin:=false;
    is_alc := row_hm.alc >= 1;
    IF NOT is_alc THEN
      BEGIN is_alc := detect_overnight_alcohol(p_user_id, d, 'Europe/Berlin');
      EXCEPTION WHEN OTHERS THEN is_alc := false; END;
    END IF;

    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'resting_hr',d,28,0);
    IF bl.rsd IS NOT NULL AND bl.n >= min_n AND row_hm.resting_hr > 0 THEN
      z := CASE WHEN is_alc THEN 0 ELSE (row_hm.resting_hr - bl.med)/GREATEST(bl.rsd, 1.5) END;
      s_rhr := GREATEST(0, s_rhr + z - k); a_rhr := s_rhr > h;
    END IF;

    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'hrv_avg',d,28,0);
    IF bl.rsd IS NOT NULL AND bl.n >= min_n AND row_hm.hrv_avg > 0 THEN
      z := CASE WHEN is_alc THEN 0 ELSE (bl.med - row_hm.hrv_avg)/GREATEST(bl.rsd, 3.0) END;
      s_rmssd := GREATEST(0, s_rmssd + z - k); a_rmssd := s_rmssd > h;
    END IF;

    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'skin_temp',d,28,0);
    skin_mand := bl.rsd IS NOT NULL AND bl.n >= min_n AND bl.rsd <= skin_max_rsd;
    IF bl.rsd IS NOT NULL AND bl.n >= min_n AND row_hm.skin_temp > 0 THEN
      z := CASE WHEN is_alc THEN 0 ELSE (row_hm.skin_temp - bl.med)/GREATEST(bl.rsd, 0.15) END;
      s_skin := GREATEST(0, s_skin + z - k); a_skin := s_skin > h;
    END IF;

    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'respiratory_rate',d,74,14);
    IF bl.rsd IS NOT NULL AND bl.n >= min_n AND row_hm.respiratory_rate BETWEEN 10 AND 24 THEN
      z := CASE WHEN is_alc THEN 0 ELSE (row_hm.respiratory_rate - bl.med)/GREATEST(bl.rsd, 0.8) END;
      s_resp := GREATEST(0, s_resp + z - k); a_resp := s_resp > h;
    END IF;

    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'pnn50_avg',d,28,0);
    IF bl.rsd IS NOT NULL AND bl.n >= min_n AND row_hm.pnn50_avg > 0 THEN
      z := CASE WHEN is_alc THEN 0 ELSE (bl.med - row_hm.pnn50_avg)/GREATEST(bl.rsd, 2.0) END;
      s_pnn := GREATEST(0, s_pnn + z - k); a_pnn := s_pnn > h;
    END IF;

    p_rhr   := CASE WHEN a_rhr   THEN p_rhr+1   ELSE 0 END;
    p_rmssd := CASE WHEN a_rmssd THEN p_rmssd+1 ELSE 0 END;
    p_skin  := CASE WHEN a_skin  THEN p_skin+1  ELSE 0 END;
  END LOOP;

  SELECT count(*) INTO n_eps FROM illness_ground_truth_labels WHERE user_id=p_user_id;

  IF NOT last_present THEN
    v_tier := NULL; v_score := NULL;
    v_sig := jsonb_build_object('no_data', true, 'tuning', 'v3: no complete night with RHR/HRV');
    v_note := 'No usable night: nothing to score.';
  ELSE
    mand_alarms  := a_rhr::int + a_rmssd::int + CASE WHEN skin_mand THEN a_skin::int ELSE 0 END;
    bonus_alarms := a_pnn::int + a_resp::int + CASE WHEN skin_mand THEN 0 ELSE a_skin::int END;
    mand_persist := GREATEST(CASE WHEN a_rhr THEN p_rhr ELSE 0 END,
                             CASE WHEN a_rmssd THEN p_rmssd ELSE 0 END,
                             CASE WHEN a_skin AND skin_mand THEN p_skin ELSE 0 END);
    v_score := round(LEAST(100, 100*(s_rhr+s_rmssd+s_skin)/(3*h*2)), 1);
    IF mand_alarms >= 2 AND mand_persist >= 3 THEN v_tier := 'red';
    ELSIF mand_alarms >= 1 OR mand_alarms + bonus_alarms >= 2 THEN v_tier := 'yellow';
    ELSE v_tier := 'green'; END IF;
    v_sig := jsonb_build_object(
      'cusum', jsonb_build_object('rhr',round(s_rhr,2),'rmssd',round(s_rmssd,2),'skin_temp',round(s_skin,2),
                                  'resp',round(s_resp,2),'pnn50',round(s_pnn,2)),
      'alarms', jsonb_build_object('rhr',a_rhr,'rmssd',a_rmssd,'skin_temp',a_skin,'resp',a_resp,'pnn50',a_pnn),
      'skin_temp_mandatory', skin_mand, 'alcohol_night', is_alc,
      'mandatory_alarms', mand_alarms, 'persistence', mand_persist,
      'tuning', 'v3: partial nights skipped, no-data null, gap reset 3, min_n 10, alcohol zeroed, skin mandatory only if robust SD<=0.5C, resp 10-24');
    v_note := CASE WHEN n_eps = 0 THEN 'baseline-only, no validated episodes yet'
                   ELSE format('n=%s labeled episodes, directional only', n_eps) END;
  END IF;

  UPDATE health_metrics SET illness_v2_score=v_score, illness_v2_tier=v_tier,
         illness_v2_note=v_note, illness_v2_signals=v_sig
   WHERE user_id=p_user_id AND metric_date=p_date;

  tier:=v_tier; score:=v_score; signals:=v_sig; RETURN NEXT;
END;
$function$;


-- PROPOSAL illness display + lag (NOT RUN). Two small changes.
--
-- A) The app's Today card calls illness_risk_now (TodayView.swift:100 -> SupabaseClient.fetchIllnessRisk);
--    illness_v2 (the CuSum ensemble) is shown nowhere and only gates compute_fitness_week. Fold the v2
--    tier into illness_risk_now so a slow multi-night drift can reach the card. Still STABLE/read-only.
--    Read-only backtest of the live card logic over 2026-07-10..10-07 with as-of 30-day baselines:
--    0 elevated by 2-night rule, 1 'spike' elevated (08-29), 2 watch (09-02, 10-07); with today's
--    baseline snapshot: 1 watch (10-07), 30 no_data, 60 clear. Adding the v3 tier adds 1 watch (08-16).
--
-- B) Lag: compute_frontier_nightly (cron 46, 05:45 UTC) scores today-3..today-1 only, so last night's
--    illness_v2 tier is first written ~24 h after waking (10-08 row: illness_v2_tier NULL at 10:45 Berlin;
--    10-07 was scored on the morning of 10-08). Add a same-morning run.

-- A)
CREATE OR REPLACE FUNCTION public.illness_risk_now(p_user_id uuid, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE d date; rhrmed numeric; rhrmad numeric; hrvmed numeric; hrvmad numeric;
  cur_rhr numeric; cur_hrv numeric; cur_alc numeric; prev_rhr numeric; prev_hrv numeric; prev_alc numeric; prev_date date;
  rhr_unreliable boolean; hrv_unreliable boolean;
  cur_rd numeric; cur_hd numeric; prev_rd numeric; prev_hd numeric;
  cur_comb numeric; prev_comb numeric; padj boolean; sustained boolean; spike boolean; escalate boolean;
  risk numeric; level text; note text; was_alc boolean; prev_was_alc boolean;
  v2_tier text; v2_alarms text;
  -- calibrated 2026-07-10 (finding #5/#23/#26): floor MAD so integer RHR jitter is not multi-sigma,
  -- require BOTH RHR and HRV elevated (min of the two, not the mean), risk banded to match level.
  c_watch constant numeric := 1.75;   -- both signals >=1.75 MAD-units off => "watch"
  c_spike constant numeric := 2.5;    -- one very sharp night => escalate to "elevated"
  c_sust  constant numeric := 1.75;   -- two adjacent nights both >=c_sust => "elevated"
BEGIN
  IF p_date IS NULL THEN SELECT max(metric_date) INTO d FROM health_metrics WHERE user_id=p_user_id AND sleep_hours>0; ELSE d := p_date; END IF;
  SELECT median,mad INTO rhrmed,rhrmad FROM personal_baselines WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  SELECT median,mad INTO hrvmed,hrvmad FROM personal_baselines WHERE user_id=p_user_id AND metric='hrv_avg' AND window_days=30;
  rhrmad:=GREATEST(COALESCE(rhrmad,3),3); hrvmad:=GREATEST(COALESCE(hrvmad,4),4);
  rhrmed:=COALESCE(rhrmed,50); hrvmed:=COALESCE(hrvmed,50.65);

  SELECT resting_hr,hrv_avg,COALESCE(alcohol_impact,0) INTO cur_rhr,cur_hrv,cur_alc FROM health_metrics WHERE user_id=p_user_id AND metric_date=d;
  SELECT resting_hr,hrv_avg,COALESCE(alcohol_impact,0),metric_date INTO prev_rhr,prev_hrv,prev_alc,prev_date
    FROM health_metrics WHERE user_id=p_user_id AND metric_date<d AND sleep_hours>0 ORDER BY metric_date DESC LIMIT 1;

  IF cur_rhr IS NULL OR cur_hrv IS NULL THEN RETURN jsonb_build_object('risk',0,'level','no_data','note','No night to score.'); END IF;

  -- #26: implausible resting readings are data errors, not illness. Zero their contribution.
  rhr_unreliable := (cur_rhr < 30 OR cur_rhr > 85);
  hrv_unreliable := (cur_hrv <= 0 OR cur_hrv > 200);
  IF rhr_unreliable AND hrv_unreliable THEN
    RETURN jsonb_build_object('date',d,'risk',0,'level','no_data','note','Readings out of range tonight — no clean resting signal to score.','rhr',cur_rhr,'hrv',cur_hrv,'sustained',false,'was_alcohol',false);
  END IF;

  was_alc:=(cur_alc>=1);
  IF NOT was_alc THEN BEGIN was_alc:=detect_overnight_alcohol(p_user_id,d,'Europe/Berlin'); EXCEPTION WHEN OTHERS THEN was_alc:=false; END; END IF;
  prev_was_alc:=(prev_alc>=1);

  -- deviations (0 if the signal is unreliable so a garbage reading can neither alarm nor corroborate)
  cur_rd := CASE WHEN rhr_unreliable THEN 0 ELSE GREATEST(0,(cur_rhr-rhrmed)/rhrmad) END;
  cur_hd := CASE WHEN hrv_unreliable THEN 0 ELSE GREATEST(0,(hrvmed-cur_hrv)/hrvmad) END;
  cur_comb := LEAST(cur_rd, cur_hd);          -- BOTH must be elevated (min), not the mean
  IF was_alc THEN cur_comb:=0; END IF;

  IF prev_rhr IS NOT NULL AND prev_hrv IS NOT NULL AND NOT (prev_rhr<30 OR prev_rhr>85) AND NOT (prev_hrv<=0 OR prev_hrv>200) THEN
    prev_rd := GREATEST(0,(prev_rhr-rhrmed)/rhrmad);
    prev_hd := GREATEST(0,(hrvmed-prev_hrv)/hrvmad);
    prev_comb := LEAST(prev_rd, prev_hd);
    IF prev_was_alc THEN prev_comb:=0; END IF;
  ELSE prev_comb:=0; END IF;

  -- #26: only "sustained" if the prior scored night is within 2 calendar days (no wear-gap bridging)
  padj := (prev_date IS NOT NULL AND (d - prev_date) <= 2);
  sustained := (padj AND cur_comb>=c_sust AND prev_comb>=c_sust);
  spike := (cur_comb >= c_spike);
  escalate := (sustained OR spike);

  -- #23: risk is banded to the level so the number can never contradict the label
  IF cur_comb < c_watch THEN
    level:='clear'; risk:=LEAST(24, round(cur_comb*14));
  ELSIF NOT escalate THEN
    level:='watch'; risk:=LEAST(49, GREATEST(25, round(cur_comb*18)));
  ELSE
    level:='elevated'; risk:=LEAST(100, GREATEST(50, round(cur_comb*28)));
  END IF;

  IF was_alc THEN note:='Signals up but that reads as alcohol, not illness. Skipped.';
  ELSIF rhr_unreliable OR hrv_unreliable THEN note:='Could not get a clean resting read tonight (RHR/HRV out of range) — nothing to flag from this one.';
  ELSIF level='clear' THEN note:='All clear. RHR and HRV at your normal.';
  ELSIF level='watch' THEN note:='Something is off tonight (RHR '||round(cur_rhr)||' vs '||round(rhrmed)||', HRV '||round(cur_hrv)||' vs '||round(hrvmed)||'). Could be a hard day or the start of something. Keep an eye.';
  ELSIF spike AND NOT sustained THEN note:='One sharp night — RHR up and HRV down together (RHR '||round(cur_rhr)||' vs '||round(rhrmed)||', HRV '||round(cur_hrv)||' vs '||round(hrvmed)||'). Not a trend yet; if it holds tomorrow, treat it as real.';
  ELSE note:='Two nights of elevated RHR + suppressed HRV, not a blip. Your body may be fighting something. Rest, hydrate, no booze, no hard training.'; END IF;

  -- v198: surface the multi-night CuSum drift (illness_cusum_ensemble) in the one card the app shows.
  -- A slow 3-5 night rise never trips the 1-2 night rule above, and illness_v2 is shown nowhere today.
  SELECT illness_v2_tier,
         (SELECT string_agg(key, ',') FROM jsonb_each_text(illness_v2_signals->'alarms') WHERE value = 'true')
    INTO v2_tier, v2_alarms
    FROM health_metrics WHERE user_id=p_user_id AND metric_date=d;
  IF NOT was_alc AND v2_tier = 'red' AND level <> 'elevated' THEN
    level:='elevated'; risk:=GREATEST(risk,50);
    note:='Several nights in a row off your baseline ('||COALESCE(v2_alarms,'multi-signal')||'). Treat it as real: rest, no booze, no hard training.';
  ELSIF NOT was_alc AND v2_tier = 'yellow' AND level = 'clear' THEN
    level:='watch'; risk:=GREATEST(risk,25);
    note:='Tonight looks normal, but the last few nights have been drifting ('||COALESCE(v2_alarms,'one signal')||'). Keep an eye.';
  END IF;

  RETURN jsonb_build_object('date',d,'risk',risk,'level',level,'note',note,'rhr',cur_rhr,'hrv',cur_hrv,'sustained',sustained,'was_alcohol',was_alc,'v2_tier',v2_tier);
END;$function$;


-- B) same-morning scoring (cron.timezone is GMT: 06:00 and 10:00 UTC = 08:00 and 12:00 Berlin in CEST)
SELECT cron.schedule('illness_cusum_today', '0 6,10 * * *',
  $$SELECT public.illness_cusum_ensemble('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, (now() AT TIME ZONE 'Europe/Berlin')::date)$$);

-- The night that just ended is metric_date = today; job 10 only finalises yesterday at 07:00 Berlin.
SELECT cron.schedule('recompute_today_noon', '55 9 * * *',
  $$SELECT public.recompute_health_metrics('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, (now() AT TIME ZONE 'Europe/Berlin')::date)$$);


CREATE OR REPLACE FUNCTION public.body_battery_at(p_user_id uuid, p_at timestamp with time zone)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
-- v198: body_battery_now with the clock as a parameter, so a past day can be replayed.
DECLARE base numeric; peak numeric; adj numeric; wk timestamptz; sev numeric;
        drain numeric; d date;
BEGIN
  SELECT value INTO base FROM body_battery_curve(p_user_id, p_at - interval '36 hours', p_at)
   ORDER BY at DESC LIMIT 1;
  IF base IS NULL THEN RETURN NULL; END IF;

  d := (p_at AT TIME ZONE 'Europe/Berlin')::date;
  SELECT wake, severity INTO wk, sev FROM body_battery_wake_inertia(p_user_id, d);

  IF wk IS NOT NULL AND p_at > wk THEN
    SELECT value INTO peak FROM body_battery_curve(p_user_id, wk - interval '36 hours', wk)
     ORDER BY at DESC LIMIT 1;
    adj := body_battery_daily_adjustment(p_user_id, d);              -- full-metric stack (recentered v153)
    peak := GREATEST(5, LEAST(100, COALESCE(peak,100) + COALESCE(adj,0)));  -- recovery-adjusted morning charge
    -- v153 (#9): replace the flat -3/h clock (which floored at 5 on long days and ignored
    -- exertion) with the adaptive body_battery_intraday_drain: 1.2 pts per waking hour
    -- (adaptive to the actual waking span) + 0.12 per bpm-hour of real intraday exertion.
    -- A typical 16-17h day now lands ~35-45, a hard-ride day drains more, a calm day less.
    drain := body_battery_intraday_drain(p_user_id, p_at);
    base := LEAST(base, peak - COALESCE(drain,0));
  END IF;

  RETURN GREATEST(5, round(base));
END;$function$;

-- health_signal_baseline: baselines from complete nights only (its one caller is illness_cusum_ensemble).
CREATE OR REPLACE FUNCTION public.health_signal_baseline(p_user_id uuid, p_signal text, p_date date, p_win integer, p_embargo integer DEFAULT 0)
 RETURNS TABLE(med numeric, rsd numeric, n integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE m numeric; mad numeric; cnt int;
BEGIN
  EXECUTE format($q$
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v), count(*)
    FROM (SELECT %I AS v FROM health_metrics
          WHERE user_id=$1 AND metric_date < $2 - $4 AND metric_date >= $2 - $3 AND %I > 0
            AND COALESCE(excluded,false)=false AND sleep_complete IS NOT FALSE) t
  $q$, p_signal, p_signal)
  INTO m, cnt USING p_user_id, p_date, p_win, p_embargo;

  IF m IS NULL THEN RETURN; END IF;

  EXECUTE format($q$
    SELECT 1.4826 * percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(%I - $5))
    FROM health_metrics
    WHERE user_id=$1 AND metric_date < $2 - $4 AND metric_date >= $2 - $3 AND %I > 0
      AND COALESCE(excluded,false)=false AND sleep_complete IS NOT FALSE
  $q$, p_signal, p_signal)
  INTO mad USING p_user_id, p_date, p_win, p_embargo, m;

  med := m; rsd := NULLIF(mad,0); n := cnt; RETURN NEXT;
END;$function$
;
