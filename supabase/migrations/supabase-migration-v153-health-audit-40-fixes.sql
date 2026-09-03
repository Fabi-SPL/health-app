-- ============================================================================
-- Migration v153 — Health Algorithm Audit: 40-finding fix batch
-- Deployed LIVE via /pg/query on 2026-07-10. Server-only (public iOS repo).
-- NOT git-committed per v108+ pattern. Record/reference only.
--
-- Source: multi-agent audit (40 findings, 14 verified high/critical) +
-- Featherless deep research on validated wearable algorithms.
-- Verified end-to-end: body battery ~100 after great night, sleep target 8.5h,
-- oversleep != 100, illness FP 40%->13%, wake anchor 08:00, alcohol catches
-- moderate nights, RHR baseline p05=49. 30-day history re-derived, 0 errors.
-- ============================================================================


-- ============================================================================
-- GROUP: sleep
-- ============================================================================
-- ================ RE-SEED (finding #1) — personal_priors.optimal_sleep_hours ================
-- Single refresh() call could not move the rigid Bayesian posterior (tau2 collapsed to 0.009
-- over 39 ~10h observations), so the accumulator was reset directly to the fixed dose-response
-- knee (8h) with loosened variance; the now-fixed nightly refresh maintains it at 8.
UPDATE personal_priors
SET mu = 8, tau2 = 1.0, n_obs = 1, prior_mu = 8, prior_tau2 = 1.0, updated_at = now()
WHERE user_id='372210e5-1dda-41b3-b759-5ff72293b8ff' AND param='optimal_sleep_hours';

-- ================ refresh_optimal_sleep_prior (finding #1) ================
CREATE OR REPLACE FUNCTION public.refresh_optimal_sleep_prior(p_user_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE best_h numeric;
BEGIN
  -- v153 (finding #1): sample-weighted dose-response over PHYSIOLOGICAL durations only.
  -- Old code took argmax-of-noisy-bucket (ORDER BY median-recovery DESC LIMIT 1, n>=3),
  -- learning 11h as "optimal" via reverse causation (long sleep on rest/recovery days).
  -- Fix: (a) restrict to 5-9h band, (b) drop illness/alcohol nights, (c) require n>=8,
  -- (d) take the KNEE (smallest duration within 3 pts of peak), (e) hard-clamp <=9h.
  SELECT min(hrs) INTO best_h
  FROM (
    SELECT hrs, mr, max(mr) OVER () AS peak
    FROM (
      SELECT round(sleep_hours) AS hrs,
             count(*) AS c,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY recovery_score) AS mr
      FROM health_metrics
      WHERE user_id=p_user_id AND sleep_hours > 0 AND recovery_score > 0
        AND round(sleep_hours) BETWEEN 5 AND 9
        AND COALESCE(illness_risk,0) < 1
        AND COALESCE(alcohol_impact,0) < 1
        AND metric_date >= CURRENT_DATE - 120
      GROUP BY round(sleep_hours)
      HAVING count(*) >= 8
    ) b
  ) z
  WHERE mr >= peak - 3;

  IF best_h IS NOT NULL THEN
    best_h := LEAST(best_h, 9);
    PERFORM update_personal_prior(p_user_id, 'optimal_sleep_hours', best_h, 0.6);
  END IF;
  RETURN best_h;
END;$function$;

-- ================ compute_sleep_debt (finding #16) ================
CREATE OR REPLACE FUNCTION public.compute_sleep_debt(p_user_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE base numeric; debt numeric;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);
  -- v153 (finding #16): cap each night's deficit at 2h so an ordinary ~7h week can't
  -- manufacture 21h and a single very short night can't dominate the debt channel.
  SELECT COALESCE(sum(LEAST(2, GREATEST(0, base - sleep_hours))), 0) INTO debt
  FROM health_metrics
  WHERE user_id=p_user_id AND sleep_hours > 0
    AND metric_date >= CURRENT_DATE - 7 AND metric_date < CURRENT_DATE;
  RETURN ROUND(debt, 2);
END;$function$;

-- ================ compute_sleep_score (finding #2) ================
CREATE OR REPLACE FUNCTION public.compute_sleep_score(p_total_minutes integer, p_asleep_minutes integer, p_deep_min integer, p_rem_min integer, p_efficiency_pct integer)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  w_duration   numeric := 0.35;
  w_efficiency numeric := 0.25;
  w_stage      numeric := 0.20;
  w_consistency numeric := 0.20;
  duration_hours numeric;
  duration_score numeric;
  efficiency_score numeric;
  deep_pct numeric;
  rem_pct numeric;
  deep_score numeric;
  rem_score numeric;
  stage_score numeric;
  consistency_score numeric := 50;
  total_score numeric;
BEGIN
  IF p_asleep_minutes IS NULL OR p_asleep_minutes = 0 THEN RETURN 0; END IF;

  duration_hours := p_asleep_minutes / 60.0;

  -- 1. Duration tier
  IF duration_hours BETWEEN 7 AND 9 THEN
    duration_score := 100;
  ELSIF duration_hours > 9 THEN
    -- v153 (finding #2): oversleep tier BEFORE the >=6 ramp. Restores a monotone
    -- penalty past 9h so groggy 10-12h nights no longer score a perfect 100.
    duration_score := GREATEST(60, 100 - (duration_hours - 9) * 20);
  ELSIF duration_hours >= 6 THEN
    duration_score := 70 + (duration_hours - 6) * 30;
  ELSIF duration_hours >= 5 THEN
    duration_score := 40 + (duration_hours - 5) * 30;
  ELSE
    duration_score := GREATEST(duration_hours / 5.0 * 40, 0);
  END IF;

  -- 2. Efficiency tier
  IF p_efficiency_pct >= 90 THEN
    efficiency_score := 100;
  ELSIF p_efficiency_pct >= 80 THEN
    efficiency_score := 70 + (p_efficiency_pct - 80) * 3;
  ELSE
    efficiency_score := GREATEST(p_efficiency_pct / 80.0 * 70, 0);
  END IF;

  -- 3. Stage balance
  deep_pct := (p_deep_min::numeric / p_asleep_minutes) * 100;
  rem_pct  := (p_rem_min::numeric  / p_asleep_minutes) * 100;
  deep_score := CASE WHEN deep_pct BETWEEN 18 AND 30 THEN 100
                     ELSE GREATEST(0, 100 - ABS(deep_pct - 23) * 5) END;
  rem_score  := CASE WHEN rem_pct  BETWEEN 20 AND 32 THEN 100
                     ELSE GREATEST(0, 100 - ABS(rem_pct - 26) * 5) END;
  stage_score := (deep_score + rem_score) / 2.0;

  total_score := duration_score   * w_duration
               + efficiency_score * w_efficiency
               + stage_score      * w_stage
               + consistency_score * w_consistency;

  RETURN ROUND(LEAST(100, GREATEST(0, total_score)));
END;
$function$;

-- ================ detect_sleep_window (findings #3, #15, #17) ================
CREATE OR REPLACE FUNCTION public.detect_sleep_window(p_user_id uuid, p_target_date date, p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS TABLE(o_sleep_start timestamp with time zone, o_sleep_end timestamp with time zone, o_total_min integer, o_asleep_min integer, o_deep_min integer, o_rem_min integer, o_light_min integer, o_awake_min integer, o_efficiency_pct integer, o_hrv_avg numeric, o_resting_hr integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  win_start timestamptz := ((p_target_date - 1)::text || ' 19:00:00')::timestamp AT TIME ZONE p_user_tz;
  win_end   timestamptz := (p_target_date::text     || ' 12:00:00')::timestamp AT TIME ZONE p_user_tz;
  sleep_thresh int := 65;
  wake_thresh  int := 79;
  deep_ceiling int := 54;
  rem_sd_min   numeric := 3.0;
  bridge_max   int := 20;
  rhr_floor    int := 35;
  resp_thresh  numeric := 21.0;
  resp_sleep_thresh numeric := 21.0;
  is_alcohol   boolean := false;
  night_p05    int := NULL;
  adj          int := 0;
BEGIN
  SELECT detect_overnight_alcohol(p_user_id, p_target_date, p_user_tz) INTO is_alcohol;
  IF is_alcohol THEN
    sleep_thresh := 75; wake_thresh := 89; deep_ceiling := 62; rhr_floor := 40; resp_thresh := 99;
  END IF;

  SELECT round(percentile_cont(0.05) WITHIN GROUP (ORDER BY heart_rate))::int
    INTO night_p05
  FROM realtime_health
  WHERE user_id = p_user_id
    AND recorded_at >= win_start AND recorded_at < win_end
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  IF night_p05 IS NOT NULL THEN
    adj := 12 + GREATEST(0, night_p05 - 54);
    sleep_thresh := GREATEST(sleep_thresh, LEAST(80, night_p05 + adj));
    wake_thresh  := GREATEST(wake_thresh,  LEAST(94, night_p05 + adj + 14));
    deep_ceiling := GREATEST(deep_ceiling, night_p05 + 4);
  END IF;

  RETURN QUERY
  WITH minute_buckets AS (
    SELECT
      date_trunc('minute', recorded_at) AS m_ts,
      AVG(heart_rate)::numeric AS hr_avg,
      stddev_samp(heart_rate)::numeric AS hr_sd,
      AVG(hrv_rmssd)::numeric AS hrv_avg,
      -- v153 (finding #17): drop respiratory_rate=24 sentinel, matching compute_sleep_readiness.
      AVG(respiratory_rate) FILTER (WHERE respiratory_rate > 0 AND respiratory_rate < 24)::numeric AS resp_avg
    FROM realtime_health
    WHERE user_id = p_user_id
      AND recorded_at >= win_start AND recorded_at <  win_end
      AND heart_rate IS NOT NULL AND heart_rate > 30
    GROUP BY date_trunc('minute', recorded_at)
  ),
  smoothed AS (
    SELECT m_ts, hr_avg, COALESCE(hr_sd, 0) AS hr_sd, hrv_avg,
      AVG(hr_avg) OVER (ORDER BY m_ts ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS hr_smooth,
      AVG(resp_avg) OVER (ORDER BY m_ts ROWS BETWEEN 7 PRECEDING AND 7 FOLLOWING) AS resp_smooth
    FROM minute_buckets
  ),
  flagged AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE WHEN hr_smooth < sleep_thresh THEN 1 ELSE 0 END AS raw_is_sleep FROM smoothed
  ),
  with_lag AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, raw_is_sleep,
      LAG(raw_is_sleep, 1, raw_is_sleep) OVER (ORDER BY m_ts) AS prev_is_sleep FROM flagged
  ),
  runs AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, raw_is_sleep,
      SUM(CASE WHEN raw_is_sleep != prev_is_sleep THEN 1 ELSE 0 END) OVER (ORDER BY m_ts) AS run_id FROM with_lag
  ),
  run_lengths AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, raw_is_sleep, run_id,
      COUNT(*) OVER (PARTITION BY run_id) AS run_length FROM runs
  ),
  bridged AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE WHEN raw_is_sleep = 1 THEN 1 WHEN run_length < bridge_max THEN 1 ELSE 0 END AS is_sleep FROM run_lengths
  ),
  islands AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, is_sleep,
      SUM(CASE WHEN is_sleep = 0 THEN 1 ELSE 0 END) OVER (ORDER BY m_ts) AS gap_id FROM bridged
  ),
  sleep_islands AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, gap_id - 1 AS island_id FROM islands WHERE is_sleep = 1
  ),
  longest_island AS (
    SELECT island_id FROM sleep_islands GROUP BY island_id ORDER BY COUNT(*) DESC LIMIT 1
  ),
  island_minutes AS (
    SELECT s.m_ts, s.hr_avg, s.hr_sd, s.hrv_avg, s.hr_smooth, sm.resp_smooth
    FROM sleep_islands s JOIN longest_island li ON s.island_id = li.island_id JOIN smoothed sm ON sm.m_ts = s.m_ts
  ),
  island_fwd AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      AVG(CASE WHEN resp_smooth < resp_thresh THEN 1.0 ELSE 0.0 END) FILTER (WHERE resp_smooth IS NOT NULL)
        OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 19 FOLLOWING) AS fwd_low_frac FROM island_minutes
  ),
  onset_anchor AS (
    SELECT COALESCE(MIN(m_ts) FILTER (WHERE fwd_low_frac >= 0.6 AND hr_smooth < sleep_thresh), MIN(m_ts)) AS real_onset FROM island_fwd
  ),
  sleep_minutes AS (
    SELECT im.m_ts, im.hr_avg, im.hr_sd, im.hrv_avg, im.hr_smooth FROM island_minutes im, onset_anchor oa WHERE im.m_ts >= oa.real_onset
  ),
  night_floor AS (
    SELECT percentile_cont(0.10) WITHIN GROUP (ORDER BY hr_smooth) AS floor_hr FROM sleep_minutes
  ),
  wake_tail AS (
    SELECT sm.m_ts, sm.hr_smooth, nf.floor_hr,
      AVG(CASE WHEN sm.hr_smooth >= nf.floor_hr + 9 THEN 1.0 ELSE 0.0 END) OVER (ORDER BY sm.m_ts ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS tail_hi,
      COUNT(*) OVER (ORDER BY sm.m_ts ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS tail_n
    FROM sleep_minutes sm CROSS JOIN night_floor nf
  ),
  wake_anchor AS (
    SELECT COALESCE(MIN(m_ts) FILTER (WHERE tail_hi >= 0.55 AND tail_n >= 15 AND hr_smooth >= floor_hr + 9 AND m_ts >= (SELECT MIN(m_ts) FROM sleep_minutes) + interval '4 hours'),
      (SELECT MAX(m_ts) FROM sleep_minutes) + interval '1 minute') AS real_wake FROM wake_tail
  ),
  core_minutes AS (
    SELECT sm.* FROM sleep_minutes sm, wake_anchor wa WHERE sm.m_ts < wa.real_wake
  ),
  onset0 AS (SELECT MIN(m_ts) AS ms FROM core_minutes),
  pre_cand AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, is_presleep,
      AVG(is_presleep::numeric) OVER (ORDER BY m_ts ROWS BETWEEN 4 PRECEDING AND 4 FOLLOWING) AS ps_frac
    FROM (
      SELECT sm.m_ts, sm.hr_avg, sm.hr_sd, sm.hrv_avg, sm.hr_smooth,
        CASE WHEN sm.hr_smooth < wake_thresh AND sm.resp_smooth IS NOT NULL AND sm.resp_smooth < resp_sleep_thresh THEN 1 ELSE 0 END AS is_presleep
      FROM smoothed sm, onset0 o WHERE NOT is_alcohol AND sm.m_ts < o.ms AND sm.m_ts >= o.ms - interval '4 hours'
    ) q
  ),
  pre_break AS (SELECT MAX(m_ts) AS bk FROM pre_cand WHERE ps_frac < 0.5),
  prepend_minutes AS (
    SELECT pc.m_ts, pc.hr_avg, pc.hr_sd, pc.hrv_avg, pc.hr_smooth FROM pre_cand pc, pre_break pb
    WHERE pc.is_presleep = 1 AND (pb.bk IS NULL OR pc.m_ts > pb.bk)
  ),
  final_minutes AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth FROM core_minutes
    UNION ALL
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth FROM prepend_minutes
  ),
  -- v153: enrich each minute with smoothed respiration + the night's HR floor (findings #3/#15).
  fm_enriched AS (
    SELECT fm.m_ts, fm.hr_avg, fm.hr_sd, fm.hrv_avg, fm.hr_smooth, sm.resp_smooth, nf.floor_hr
    FROM final_minutes fm LEFT JOIN smoothed sm ON sm.m_ts = fm.m_ts CROSS JOIN night_floor nf
  ),
  -- v153 (finding #3): WASO relative to the night floor -> sustained hr_smooth>=floor+9.
  awake_flagged AS (
    SELECT fe.*,
      AVG(CASE WHEN hr_smooth >= COALESCE(floor_hr, 999) + 9 THEN 1.0 ELSE 0.0 END)
        OVER (ORDER BY m_ts ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS hi_frac FROM fm_enriched fe
  ),
  staged1 AS (
    SELECT aw.*,
      CASE
        WHEN hr_smooth > wake_thresh OR hi_frac >= 0.5 THEN 'awake'
        WHEN hr_smooth < deep_ceiling AND hr_sd < 3 AND COALESCE(resp_smooth, 0) < 20 THEN 'deepcand'
        WHEN hr_sd > rem_sd_min THEN 'rem'
        ELSE 'light'
      END AS s1
    FROM awake_flagged aw
  ),
  asleep_ct AS (SELECT count(*) FILTER (WHERE s1 <> 'awake') AS asleep_n FROM staged1),
  ranked AS (
    SELECT s.*,
      CASE WHEN s1 = 'deepcand' THEN row_number() OVER (PARTITION BY (s1 = 'deepcand') ORDER BY hr_smooth ASC, hr_sd ASC) END AS deep_rank
    FROM staged1 s
  ),
  -- v153 (finding #15): cap deep at 30% of asleep; demote excess (highest-HR) deep to light.
  classified AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN s1 = 'awake' THEN 'awake'
        WHEN s1 = 'rem'   THEN 'rem'
        WHEN s1 = 'light' THEN 'light'
        WHEN s1 = 'deepcand' AND deep_rank <= floor(0.30 * (SELECT asleep_n FROM asleep_ct)) THEN 'deep'
        ELSE 'light'
      END AS stage
    FROM ranked
  ),
  totals AS (
    SELECT
      MIN(m_ts) AS w_start,
      MAX(m_ts) + interval '1 minute' AS w_end,
      COUNT(*) FILTER (WHERE stage = 'deep')::int  AS deep_m,
      COUNT(*) FILTER (WHERE stage = 'rem')::int   AS rem_m,
      COUNT(*) FILTER (WHERE stage = 'light')::int AS light_m,
      COUNT(*) FILTER (WHERE stage = 'awake')::int AS awake_m,
      AVG(hrv_avg) FILTER (WHERE hrv_avg > 0)::numeric AS hrv_mean,
      percentile_cont(0.05) WITHIN GROUP (ORDER BY hr_avg) FILTER (WHERE hr_avg > rhr_floor)::numeric AS rhr_p5
    FROM classified
  )
  SELECT
    w_start, w_end,
    EXTRACT(epoch FROM (w_end - w_start))::int / 60 AS total_min,
    (deep_m + rem_m + light_m) AS asleep_min,
    deep_m, rem_m, light_m, awake_m,
    CASE WHEN (deep_m + rem_m + light_m + awake_m) > 0
         THEN ROUND(((deep_m + rem_m + light_m)::numeric / (deep_m + rem_m + light_m + awake_m)) * 100)::int
         ELSE 0 END AS eff_pct,
    ROUND(hrv_mean, 1) AS hrv_avg_out,
    ROUND(rhr_p5)::int AS rhr_out
  FROM totals
  WHERE w_start IS NOT NULL;
END;
$function$;

-- ============================================================================
-- GROUP: recovery
-- ============================================================================
-- ================= illness_risk_now (findings #5, #23, #26) =================
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
  c_watch constant numeric := 1.75;
  c_spike constant numeric := 2.5;
  c_sust  constant numeric := 1.75;
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

  rhr_unreliable := (cur_rhr < 30 OR cur_rhr > 85);
  hrv_unreliable := (cur_hrv <= 0 OR cur_hrv > 200);
  IF rhr_unreliable AND hrv_unreliable THEN
    RETURN jsonb_build_object('date',d,'risk',0,'level','no_data','note','Readings out of range tonight — no clean resting signal to score.','rhr',cur_rhr,'hrv',cur_hrv,'sustained',false,'was_alcohol',false);
  END IF;

  was_alc:=(cur_alc>=1);
  IF NOT was_alc THEN BEGIN was_alc:=detect_overnight_alcohol(p_user_id,d,'Europe/Berlin'); EXCEPTION WHEN OTHERS THEN was_alc:=false; END; END IF;
  prev_was_alc:=(prev_alc>=1);

  cur_rd := CASE WHEN rhr_unreliable THEN 0 ELSE GREATEST(0,(cur_rhr-rhrmed)/rhrmad) END;
  cur_hd := CASE WHEN hrv_unreliable THEN 0 ELSE GREATEST(0,(hrvmed-cur_hrv)/hrvmad) END;
  cur_comb := LEAST(cur_rd, cur_hd);
  IF was_alc THEN cur_comb:=0; END IF;

  IF prev_rhr IS NOT NULL AND prev_hrv IS NOT NULL AND NOT (prev_rhr<30 OR prev_rhr>85) AND NOT (prev_hrv<=0 OR prev_hrv>200) THEN
    prev_rd := GREATEST(0,(prev_rhr-rhrmed)/rhrmad);
    prev_hd := GREATEST(0,(hrvmed-prev_hrv)/hrvmad);
    prev_comb := LEAST(prev_rd, prev_hd);
    IF prev_was_alc THEN prev_comb:=0; END IF;
  ELSE prev_comb:=0; END IF;

  padj := (prev_date IS NOT NULL AND (d - prev_date) <= 2);
  sustained := (padj AND cur_comb>=c_sust AND prev_comb>=c_sust);
  spike := (cur_comb >= c_spike);
  escalate := (sustained OR spike);

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

  RETURN jsonb_build_object('date',d,'risk',risk,'level',level,'note',note,'rhr',cur_rhr,'hrv',cur_hrv,'sustained',sustained,'was_alcohol',was_alc);
END;$function$;

-- ================= clean_skin_temp_day (finding #25) =================
CREATE OR REPLACE FUNCTION public.clean_skin_temp_day(p_user_id uuid, p_date date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  day_start timestamptz := ((p_date::text            || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin';
  day_end   timestamptz := (((p_date + 1)::text      || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin';
  lo    constant numeric := 28.0;
  hi    constant numeric := 39.0;
  slew  constant numeric := 2.5;
  raw_med numeric;
  n_gated int;
  base    numeric;
  d_rhr numeric; d_hrv numeric; rhrmed numeric; rhrmad numeric; hrvmed numeric; hrvmad numeric;
  rhr_hi boolean; hrv_lo boolean;
BEGIN
  SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY skin_temp)::numeric, 1),
         count(*)
    INTO raw_med, n_gated
  FROM realtime_health
  WHERE user_id = p_user_id
    AND recorded_at >= day_start AND recorded_at < day_end
    AND skin_temp IS NOT NULL
    AND skin_temp >= lo AND skin_temp <= hi;

  IF n_gated = 0 OR raw_med IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY skin_temp)
    INTO base
  FROM health_metrics
  WHERE user_id = p_user_id
    AND metric_date < p_date AND metric_date >= p_date - 14
    AND skin_temp IS NOT NULL AND skin_temp >= lo AND skin_temp <= hi;

  IF base IS NOT NULL AND abs(raw_med - base) > slew THEN
    IF raw_med > base THEN
      SELECT resting_hr, hrv_avg INTO d_rhr, d_hrv
        FROM health_metrics WHERE user_id = p_user_id AND metric_date = p_date;
      SELECT median, mad INTO rhrmed, rhrmad
        FROM personal_baselines WHERE user_id = p_user_id AND metric='resting_hr' AND window_days=30;
      SELECT median, mad INTO hrvmed, hrvmad
        FROM personal_baselines WHERE user_id = p_user_id AND metric='hrv_avg' AND window_days=30;
      rhrmad := GREATEST(COALESCE(rhrmad,3),3);
      hrvmad := GREATEST(COALESCE(hrvmad,4),4);
      rhr_hi := (d_rhr IS NOT NULL AND rhrmed IS NOT NULL AND (d_rhr - rhrmed)/rhrmad >= 1.0);
      hrv_lo := (d_hrv IS NOT NULL AND d_hrv > 0 AND hrvmed IS NOT NULL AND (hrvmed - d_hrv)/hrvmad >= 1.0);
      IF rhr_hi OR hrv_lo THEN
        RETURN base + slew;
      ELSE
        RETURN NULL;
      END IF;
    ELSE
      RETURN NULL;
    END IF;
  END IF;

  RETURN raw_med;
END;
$function$;

-- ================= compute_recovery_score (findings #24, #27, #29 + SHARED CONTRACT) =================
DROP FUNCTION IF EXISTS public.compute_recovery_score(uuid, numeric, integer, numeric);

CREATE OR REPLACE FUNCTION public.compute_recovery_score(
  p_user_id uuid, p_hrv_avg numeric, p_resting_hr numeric, p_sleep_score numeric,
  p_date date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  history_days int;
  hrv_pct numeric;
  rhr_pct_inv numeric;
  s_score numeric;
  baseline_hrv numeric;
  hrv_sd       numeric;
  median_rhr   numeric;
  rhr_sd       numeric;
  v_hrv_med numeric; v_hrv_mad numeric; v_rhr_med numeric; v_rhr_mad numeric;
  hrv_z numeric;
  rhr_z numeric;
  hrv_component numeric;
  rhr_component numeric;
  sleep_component numeric;
  total_weight numeric := 0;
  weighted_sum numeric := 0;
  raw numeric;
  recovery_anchor numeric := 66;
  stretch_k numeric := 1.15;
  score_floor numeric := 5;
BEGIN
  SELECT median, mad INTO v_hrv_med, v_hrv_mad FROM personal_baselines
    WHERE user_id=p_user_id AND metric='hrv_avg' AND window_days=30;
  SELECT median, mad INTO v_rhr_med, v_rhr_mad FROM personal_baselines
    WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  baseline_hrv := COALESCE(v_hrv_med, 64.4);
  median_rhr   := COALESCE(v_rhr_med, 58);
  hrv_sd := GREATEST(COALESCE(v_hrv_mad,0)*1.4826, 8);
  rhr_sd := GREATEST(COALESCE(v_rhr_mad,0)*1.4826, 4);

  SELECT COUNT(*) INTO history_days
  FROM health_metrics
  WHERE user_id = p_user_id
    AND hrv_avg IS NOT NULL AND hrv_avg > 0
    AND metric_date >= p_date - 30
    AND metric_date < p_date;

  IF history_days < 7 THEN
    IF p_hrv_avg IS NOT NULL AND p_hrv_avg > 0 THEN
      hrv_z := (p_hrv_avg - baseline_hrv) / hrv_sd;
      hrv_component := sigmoid(hrv_z) * 100;
    ELSE
      hrv_component := 50;
    END IF;

    IF p_resting_hr IS NOT NULL AND p_resting_hr > 0 THEN
      rhr_z := (median_rhr - p_resting_hr) / rhr_sd;
      rhr_component := sigmoid(rhr_z) * 100;
    ELSE
      rhr_component := 50;
    END IF;

    sleep_component := COALESCE(p_sleep_score, 50);

    RETURN ROUND(LEAST(100, GREATEST(score_floor,
      hrv_component * 0.50 + rhr_component * 0.20 + sleep_component * 0.30
    )));
  END IF;

  IF p_hrv_avg IS NOT NULL AND p_hrv_avg > 0 THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE hrv_avg < p_hrv_avg)::numeric +
      0.5 * COUNT(*) FILTER (WHERE hrv_avg = p_hrv_avg)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE hrv_avg > 0), 0)
    INTO hrv_pct
    FROM health_metrics
    WHERE user_id = p_user_id
      AND hrv_avg IS NOT NULL AND hrv_avg > 0
      AND metric_date >= p_date - 30
      AND metric_date < p_date;
  ELSE
    hrv_pct := NULL;
  END IF;

  IF p_resting_hr IS NOT NULL AND p_resting_hr > 0 THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE resting_hr > p_resting_hr)::numeric +
      0.5 * COUNT(*) FILTER (WHERE resting_hr = p_resting_hr)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE resting_hr > 0), 0)
    INTO rhr_pct_inv
    FROM health_metrics
    WHERE user_id = p_user_id
      AND resting_hr IS NOT NULL AND resting_hr > 0
      AND metric_date >= p_date - 30
      AND metric_date < p_date;
  ELSE
    rhr_pct_inv := NULL;
  END IF;

  IF p_sleep_score IS NOT NULL THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE sleep_score < p_sleep_score)::numeric +
      0.5 * COUNT(*) FILTER (WHERE sleep_score = p_sleep_score)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE sleep_score IS NOT NULL), 0)
    INTO s_score
    FROM health_metrics
    WHERE user_id = p_user_id
      AND sleep_score IS NOT NULL
      AND metric_date >= p_date - 30
      AND metric_date < p_date;
    s_score := COALESCE(s_score, p_sleep_score);
  ELSE
    s_score := 50;
  END IF;

  IF hrv_pct IS NOT NULL THEN
    weighted_sum := weighted_sum + hrv_pct * 0.55;
    total_weight := total_weight + 0.55;
  END IF;
  IF rhr_pct_inv IS NOT NULL THEN
    weighted_sum := weighted_sum + rhr_pct_inv * 0.30;
    total_weight := total_weight + 0.30;
  END IF;
  weighted_sum := weighted_sum + s_score * 0.15;
  total_weight := total_weight + 0.15;

  IF total_weight = 0 THEN
    RETURN 50;
  END IF;

  raw := weighted_sum / total_weight;

  RETURN ROUND(LEAST(100, GREATEST(score_floor, recovery_anchor + (raw - 50) * stretch_k)));
END;
$function$;

-- ============================================================================
-- GROUP: body-battery
-- ============================================================================
CREATE OR REPLACE FUNCTION public.body_battery_breakdown(p_user_id uuid, p_date date)
 RETURNS TABLE(component text, category text, raw numeric, points numeric, status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  WITH m AS (SELECT * FROM health_metrics WHERE user_id=p_user_id AND metric_date=p_date)
  -- v153 recenter (#6/#7/#8/#30/#32/#33): components centered on Fabi's baseline so a
  -- normal night nets ~0 and all-clear illness/load categories award small positives, so
  -- a recovery-100 night -> morning charge pk ~= 100 (was ~80).
  SELECT * FROM (
    SELECT 'deep_sleep'::text,'sleep'::text, m.deep_sleep_min::numeric,
      CASE WHEN m.deep_sleep_min IS NULL THEN 0 ELSE GREATEST(-6,LEAST(6,(m.deep_sleep_min-143)/15.0)) END,
      CASE WHEN m.deep_sleep_min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'rem_sleep','sleep', m.rem_sleep_min::numeric,
      CASE WHEN m.rem_sleep_min IS NULL THEN 0 ELSE GREATEST(-4,LEAST(4,(m.rem_sleep_min-136)/18.0)) END,
      CASE WHEN m.rem_sleep_min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'light_sleep','sleep', m.light_sleep_min::numeric, 0,
      CASE WHEN m.light_sleep_min IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'awake_waso','sleep', m.awake_min::numeric,
      CASE WHEN m.awake_min IS NULL THEN 0 WHEN m.awake_min<=15 THEN 1.0 ELSE GREATEST(-8,-(m.awake_min-15)/6.0) END,
      CASE WHEN m.awake_min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_duration','sleep', m.sleep_hours,
      CASE WHEN m.sleep_hours IS NULL THEN 0
           WHEN m.sleep_hours<7 THEN GREATEST(-12,(m.sleep_hours-7)*4)
           WHEN m.sleep_hours>10.5 THEN GREATEST(-9,(10.5-m.sleep_hours)*3)
           ELSE LEAST(1.5,(m.sleep_hours-7)*0.6) END,
      CASE WHEN m.sleep_hours IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_score','sleep', m.sleep_score,
      CASE WHEN m.sleep_score IS NULL THEN 0 ELSE GREATEST(-3,LEAST(3,(m.sleep_score-95)/8.0)) END,
      CASE WHEN m.sleep_score IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_efficiency','sleep', m.sleep_efficiency_pct,
      CASE WHEN m.sleep_efficiency_pct IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.sleep_efficiency_pct-92)/8.0)) END,
      CASE WHEN m.sleep_efficiency_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- #7: sleep_fragmentation rescaled to its TRUE 50-125 index (neutral ~= 85, scale /15)
    UNION ALL SELECT 'sleep_fragmentation','sleep', m.sleep_fragmentation::numeric,
      CASE WHEN m.sleep_fragmentation IS NULL THEN 0 ELSE GREATEST(-6,LEAST(3,(85-m.sleep_fragmentation)/15.0)) END,
      CASE WHEN m.sleep_fragmentation IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_performance','sleep', m.sleep_performance_pct,
      CASE WHEN m.sleep_performance_pct IS NULL THEN 0 ELSE GREATEST(-3,LEAST(3,(m.sleep_performance_pct-85)/10.0)) END,
      CASE WHEN m.sleep_performance_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_consistency','sleep', m.sleep_consistency_pct,
      CASE WHEN m.sleep_consistency_pct IS NULL THEN 0 ELSE GREATEST(-3,LEAST(2,(m.sleep_consistency_pct-80)/12.0)) END,
      CASE WHEN m.sleep_consistency_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- #30: sleep_debt softened to ~-1/h capped -6 and GATED against the recovery penalty
    UNION ALL SELECT 'sleep_debt','sleep', m.sleep_debt_hours,
      CASE WHEN m.sleep_debt_hours IS NULL THEN 0
           ELSE GREATEST(-6, -m.sleep_debt_hours * 1.0
                 * (CASE WHEN COALESCE(m.recovery_score,60) >= 71 THEN 0.25 ELSE 0.5 END)) END,
      CASE WHEN m.sleep_debt_hours IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'hrv_rmssd','autonomic', m.hrv_avg,
      CASE WHEN m.hrv_avg IS NULL THEN 0 ELSE GREATEST(-3,LEAST(3,(m.hrv_avg-51.5)/12.0)) END,
      CASE WHEN m.hrv_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'hrv_sdnn','autonomic', m.sdnn_avg,
      CASE WHEN m.sdnn_avg IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.sdnn_avg-50)/15.0)) END,
      CASE WHEN m.sdnn_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'hrv_pnn50','autonomic', m.pnn50_avg,
      CASE WHEN m.pnn50_avg IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.pnn50_avg-20)/15.0)) END,
      CASE WHEN m.pnn50_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'hrv_dfa_alpha1','autonomic', m.dfa_alpha1_avg::numeric,
      CASE WHEN m.dfa_alpha1_avg IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.dfa_alpha1_avg-0.9)*6)) END,
      CASE WHEN m.dfa_alpha1_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'poincare_sd1','autonomic', m.poincare_sd1::numeric,
      CASE WHEN m.poincare_sd1 IS NULL THEN 0 ELSE GREATEST(-1.5,LEAST(1.5,(m.poincare_sd1-40)/20.0)) END,
      CASE WHEN m.poincare_sd1 IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'poincare_sd2','autonomic', m.poincare_sd2::numeric,
      CASE WHEN m.poincare_sd2 IS NULL THEN 0 ELSE GREATEST(-1,LEAST(1,(m.poincare_sd2-55)/25.0)) END,
      CASE WHEN m.poincare_sd2 IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'poincare_ratio','autonomic', m.poincare_ratio::numeric, 0,
      CASE WHEN m.poincare_ratio IS NULL THEN 'dormant' ELSE 'info' END FROM m
    -- #32: nocturnal_hr_dip stored on an unverified/garbage scale (live -143..51, no recovery
    -- correlation). Score ONLY a plausible fractional dip (0..0.4); NEVER penalize. Credit
    -- revival deferred to an upstream unit fix.
    UNION ALL SELECT 'nocturnal_hr_dip','autonomic', m.nocturnal_hr_dip::numeric,
      CASE WHEN m.nocturnal_hr_dip IS NULL OR m.nocturnal_hr_dip<0 OR m.nocturnal_hr_dip>0.4 THEN 0
           ELSE LEAST(3,m.nocturnal_hr_dip*20) END,
      CASE WHEN m.nocturnal_hr_dip IS NULL THEN 'dormant'
           WHEN m.nocturnal_hr_dip<0 OR m.nocturnal_hr_dip>0.4 THEN 'sentinel' ELSE 'live' END FROM m
    UNION ALL SELECT 'baevsky_stress','autonomic', m.baevsky_stress,
      CASE WHEN m.baevsky_stress IS NULL THEN 0 ELSE GREATEST(-5,LEAST(1,(150-m.baevsky_stress)/40.0)) END,
      CASE WHEN m.baevsky_stress IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'resting_hr','autonomic', m.resting_hr::numeric,
      CASE WHEN m.resting_hr IS NULL THEN 0 ELSE GREATEST(-5,LEAST(4,-(m.resting_hr-50.5)*2)) END,
      CASE WHEN m.resting_hr IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'recovery_score','recovery', m.recovery_score,
      CASE WHEN m.recovery_score IS NULL THEN 0 ELSE GREATEST(-4,LEAST(4,(m.recovery_score-71)/15.0)) END,
      CASE WHEN m.recovery_score IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'readiness_score','recovery', m.readiness_score::numeric, 0,
      CASE WHEN m.readiness_score IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'cognitive_capacity','recovery', m.cognitive_capacity_score, 0,
      CASE WHEN m.cognitive_capacity_score IS NULL THEN 'dormant' ELSE 'info' END FROM m
    -- #6: reward a genuinely restful load day, not only punish
    UNION ALL SELECT 'strain_stress','load', m.strain_stress,
      CASE WHEN m.strain_stress IS NULL THEN 0
           WHEN m.strain_stress>12 THEN GREATEST(-8,-(m.strain_stress-12)*1.2)
           WHEN m.strain_stress<6 THEN 1.0 ELSE 0 END,
      CASE WHEN m.strain_stress IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'strain_physical','load', m.strain_physical, 0,
      CASE WHEN m.strain_physical IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'strain_autonomic','load', m.strain_autonomic, 0,
      CASE WHEN m.strain_autonomic IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'acwr','load', m.acwr,
      CASE WHEN m.acwr IS NULL THEN 0 WHEN m.acwr>1.3 THEN GREATEST(-6,-(m.acwr-1.3)*10)
           WHEN m.acwr<0.8 THEN GREATEST(-3,-(0.8-m.acwr)*5)
           WHEN m.acwr BETWEEN 0.9 AND 1.2 THEN 1.0 ELSE 0 END,
      CASE WHEN m.acwr IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'training_monotony','load', m.training_monotony,
      CASE WHEN m.training_monotony IS NULL THEN 0 WHEN m.training_monotony>2 THEN GREATEST(-5,-(m.training_monotony-2)*3) ELSE 0 END,
      CASE WHEN m.training_monotony IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'training_strain','load', m.training_strain, 0,
      CASE WHEN m.training_strain IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'edwards_trimp','load', m.edwards_trimp, 0,
      CASE WHEN m.edwards_trimp IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'workout_minutes','load', m.workout_minutes::numeric, 0,
      CASE WHEN m.workout_minutes IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'hrr_1min','fitness', m.hrr_1min::numeric,
      CASE WHEN m.hrr_1min IS NULL THEN 0 ELSE GREATEST(-1,LEAST(1.5,(m.hrr_1min-25)/15.0)) END,
      CASE WHEN m.hrr_1min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'vo2max','fitness', m.vo2max_estimate::numeric,
      CASE WHEN m.vo2max_estimate IS NULL THEN 0 ELSE GREATEST(-1,LEAST(1,(m.vo2max_estimate-45)/20.0)) END,
      CASE WHEN m.vo2max_estimate IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'skin_temp','illness', m.skin_temp,
      CASE WHEN m.skin_temp IS NULL THEN 0 ELSE GREATEST(-10,LEAST(0,-(m.skin_temp-35.5)*6)) END,
      CASE WHEN m.skin_temp IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- #33: respiratory_rate==24 is the forward-fill sentinel (no-data) -> neutral. Real readings
    -- score gently+monotone from a 16 neutral, with a small credit for calm breathing (<=16).
    -- True staleness-based sentinel detection (to score a genuine 24) deferred to upstream.
    UNION ALL SELECT 'respiratory_rate','illness', m.respiratory_rate,
      CASE WHEN m.respiratory_rate IS NULL OR m.respiratory_rate=24 THEN 0
           WHEN m.respiratory_rate<=16 THEN LEAST(1,(16-m.respiratory_rate)*0.5)
           ELSE GREATEST(-5,-(m.respiratory_rate-16)*1.2) END,
      CASE WHEN m.respiratory_rate IS NULL THEN 'dormant' WHEN m.respiratory_rate=24 THEN 'sentinel' ELSE 'live' END FROM m
    UNION ALL SELECT 'blood_oxygen','illness', m.blood_oxygen_pct,
      CASE WHEN m.blood_oxygen_pct IS NULL THEN 0
           WHEN m.blood_oxygen_pct<95 THEN GREATEST(-8,(m.blood_oxygen_pct-95)*3)
           WHEN m.blood_oxygen_pct>=98 THEN 1.0 ELSE 0 END,
      CASE WHEN m.blood_oxygen_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- #8: illness_risk is an integer LEVEL (0/1/2). Ordinal -6/level capped -15 (1=-6, 2=-12);
    -- all-clear level 0 earns +1.5.
    UNION ALL SELECT 'illness_risk','illness', m.illness_risk::numeric,
      CASE WHEN m.illness_risk IS NULL THEN 0 WHEN m.illness_risk=0 THEN 1.5
           ELSE GREATEST(-15,-m.illness_risk*6) END,
      CASE WHEN m.illness_risk IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'alcohol','behavioral', m.alcohol_impact,
      CASE WHEN m.alcohol_impact IS NULL THEN 0 ELSE GREATEST(-15,-m.alcohol_impact*12) END,
      CASE WHEN m.alcohol_impact IS NULL THEN 'dormant' ELSE 'live' END FROM m
  ) x;
$function$;

-- ================================================================
CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE base numeric; peak numeric; adj numeric; wk timestamptz; sev numeric;
        drain numeric; d date;
BEGIN
  SELECT value INTO base FROM body_battery_curve(p_user_id, now() - interval '36 hours', now())
   ORDER BY at DESC LIMIT 1;
  IF base IS NULL THEN RETURN NULL; END IF;

  d := (now() AT TIME ZONE 'Europe/Berlin')::date;
  SELECT wake, severity INTO wk, sev FROM body_battery_wake_inertia(p_user_id, d);

  IF wk IS NOT NULL AND now() > wk THEN
    SELECT value INTO peak FROM body_battery_curve(p_user_id, wk - interval '36 hours', wk)
     ORDER BY at DESC LIMIT 1;
    adj := body_battery_daily_adjustment(p_user_id, d);              -- full-metric stack (recentered v153)
    peak := GREATEST(5, LEAST(100, COALESCE(peak,100) + COALESCE(adj,0)));  -- recovery-adjusted morning charge
    -- v153 (#9): replace flat -3/h clock with adaptive body_battery_intraday_drain
    -- (1.2 pts/waking-hour + 0.12 per bpm-hour of real intraday exertion).
    drain := body_battery_intraday_drain(p_user_id, now());
    base := LEAST(base, peak - COALESCE(drain,0));
  END IF;

  RETURN GREATEST(5, round(base));
END;$function$;

-- ================================================================
CREATE OR REPLACE FUNCTION public.body_battery_series(p_user_id uuid, p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Berlin'::text))::date)
 RETURNS TABLE(at timestamp with time zone, value numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  WITH wi AS (SELECT wake, severity FROM body_battery_wake_inertia(p_user_id, p_date)),
  curve AS (
    SELECT at, value FROM body_battery_curve(
      p_user_id,
      (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin') - interval '36 hours',
      LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
    )
  ),
  pk AS (  -- morning charge = integral at wake + full-metric daily adjustment (recentered v153), clamped
    SELECT GREATEST(5, LEAST(100,
      (SELECT c.value FROM curve c, wi WHERE c.at <= wi.wake ORDER BY c.at DESC LIMIT 1)
      + body_battery_daily_adjustment(p_user_id, p_date)
    )) AS p
  )
  SELECT c.at,
    GREATEST(5, round(
      CASE
        WHEN wi.wake IS NOT NULL AND c.at > wi.wake
          -- v153 (#9): daytime decline = adaptive body_battery_intraday_drain subtracted from
          -- the recovery-adjusted morning charge, capped by the live curve (was flat -3/h).
          THEN LEAST(c.value, COALESCE((SELECT p FROM pk), 100) - body_battery_intraday_drain(p_user_id, c.at))
        ELSE
          LEAST(c.value, COALESCE((SELECT p FROM pk), c.value))
      END
    ))
  FROM curve c LEFT JOIN wi ON true
  WHERE c.at >= (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  ORDER BY c.at;
$function$;

-- ================================================================
CREATE OR REPLACE FUNCTION public.recompute_body_battery(p_user_id uuid, p_days integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r record; base_rhr numeric; eff numeric; restorative numeric; anchor numeric; n int := 0;
BEGIN
  -- v153 (#31): SINGLE SOURCE OF TRUTH. Retire the crash-0.55/refill-0.22 reservoir whose
  -- body_battery_anchor diverged ~15-20pt from the live path (never read it). Store the SAME
  -- canonical morning charge the live path computes -- clamp(100 + daily_adjustment). bb_effective
  -- keeps its meaning (all-data readiness target).
  SELECT median INTO base_rhr FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  base_rhr := COALESCE(base_rhr, 50);

  FOR r IN
    SELECT metric_date, recovery_score, sleep_hours, deep_sleep_min, rem_sleep_min,
           resting_hr, alcohol_impact, strain_stress
    FROM health_metrics
    WHERE user_id=p_user_id AND metric_date >= CURRENT_DATE - p_days
      AND recovery_score IS NOT NULL
    ORDER BY metric_date ASC
  LOOP
    restorative := COALESCE(r.deep_sleep_min,0) + COALESCE(r.rem_sleep_min,0);

    eff := r.recovery_score
         + GREATEST(-15, LEAST(5, (restorative - 280) / 12.0))
         - (CASE WHEN r.alcohol_impact = 1 THEN 12 ELSE 0 END)
         - (CASE WHEN COALESCE(r.sleep_hours,8) < 7 THEN (7 - r.sleep_hours) * 5 ELSE 0 END)
         - (CASE WHEN COALESCE(r.strain_stress,0) > 12 THEN (r.strain_stress - 12) * 1.2 ELSE 0 END)
         - (CASE WHEN COALESCE(r.resting_hr,base_rhr) > base_rhr + 4
                 THEN (r.resting_hr - (base_rhr + 4)) * 2.5 ELSE 0 END);
    eff := GREATEST(0, LEAST(100, eff));

    anchor := GREATEST(5, LEAST(100,
      100 + COALESCE(body_battery_daily_adjustment(p_user_id, r.metric_date), 0)));

    UPDATE health_metrics
       SET body_battery_anchor = round(anchor::numeric, 1),
           bb_effective        = round(eff::numeric, 1)
     WHERE user_id = p_user_id AND metric_date = r.metric_date;
    n := n + 1;
  END LOOP;
  RETURN n;
END;$function$;

-- ============================================================================
-- GROUP: circadian
-- ============================================================================
-- ==== estimate_circadian_anchor (findings #4, #18) ====
CREATE OR REPLACE FUNCTION public.estimate_circadian_anchor(p_user_id uuid, p_lookback_days integer DEFAULT 21)
 RETURNS TABLE(hr_nadir_hour numeric, cbtmin_hour numeric, optimal_wake_hour numeric, n_samples integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE hrn numeric; nsamp int; ow numeric; rise_h numeric;
BEGIN
  -- Per-clock-hour median HR across the biological night (22:00-10:00 Berlin),
  -- SMOOTHED with a 3-hour rolling mean before choosing the trough. Raw
  -- integer-HR medians sit on a flat ~1 bpm plateau (56-59) so a bare argmin
  -- coin-flips the nadir night to night (finding #18). oi = ordered night index.
  -- Optimal wake = first post-nadir hour whose smoothed HR has climbed ~4 bpm
  -- off the nadir floor; else fall back to nadir+5 -- the empirically correct
  -- late-chronotype offset (body wakes ~5h after the HR low, not the textbook
  -- 2h), matching circadian_phase's 08:30 (finding #4).
  WITH hourly AS (
    SELECT extract(hour FROM recorded_at AT TIME ZONE 'Europe/Berlin')::int AS h,
           ((extract(hour FROM recorded_at AT TIME ZONE 'Europe/Berlin')::int) + 2) % 24 AS oi,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY heart_rate) AS m,
           count(*) AS n
    FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate > 30
      AND recorded_at >= now() - make_interval(days => p_lookback_days)
      AND extract(hour FROM recorded_at AT TIME ZONE 'Europe/Berlin')::int IN (22,23,0,1,2,3,4,5,6,7,8,9)
    GROUP BY 1, 2
    HAVING count(*) >= 30
  ),
  smoothed AS (
    SELECT h, oi, n, m,
           avg(m) OVER (ORDER BY oi ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS sm
    FROM hourly
  ),
  nadir AS (
    SELECT h AS nh, oi AS noi, sm AS nval, n AS nn
    FROM smoothed ORDER BY sm ASC, oi ASC LIMIT 1
  ),
  rise AS (
    SELECT s.h AS rh
    FROM smoothed s CROSS JOIN nadir
    WHERE s.oi > nadir.noi AND s.sm >= nadir.nval + 4
    ORDER BY s.oi ASC LIMIT 1
  )
  SELECT nadir.nh, nadir.nn, rise.rh
    INTO hrn, nsamp, rise_h
  FROM nadir LEFT JOIN rise ON true;

  IF hrn IS NULL THEN RETURN; END IF;

  IF rise_h IS NOT NULL THEN
    ow := rise_h;
  ELSE
    ow := hrn + 5;
  END IF;
  IF ow >= 24 THEN ow := ow - 24; END IF;
  -- Never recommend a pre-08:00 circadian wake for this documented late
  -- chronotype; clamp into the 08:00-09:00 band circadian_phase specifies.
  ow := GREATEST(8, LEAST(9, ow));

  hr_nadir_hour := hrn;
  -- CBTmin trails the HR nadir by a couple of hours; do NOT equate the two (finding #4).
  cbtmin_hour := hrn + 2.5;
  IF cbtmin_hour >= 24 THEN cbtmin_hour := cbtmin_hour - 24; END IF;
  optimal_wake_hour := ow;
  n_samples := nsamp;
  RETURN NEXT;
END;$function$;

-- ==== body_battery_wake_inertia (finding #20) ====
CREATE OR REPLACE FUNCTION public.body_battery_wake_inertia(p_user_id uuid, p_date date)
 RETURNS TABLE(wake timestamp with time zone, severity numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE w timestamptz; sh numeric; deep numeric; woke_deep boolean;
BEGIN
  SELECT sleep_end, sleep_hours, deep_sleep_min INTO w, sh, deep
   FROM health_metrics WHERE user_id=p_user_id AND metric_date=p_date;
  IF w IS NULL THEN RETURN; END IF;

  -- did he surface straight out of deep sleep? (harder inertia)
  SELECT (mode() WITHIN GROUP (ORDER BY sleep_stage)) = 'deep' INTO woke_deep
   FROM realtime_health
   WHERE user_id=p_user_id AND recorded_at BETWEEN w - interval '15 min' AND w;

  wake := w;
  severity :=  10                                                   -- base fog
    + (CASE WHEN COALESCE(woke_deep,false) THEN 12 ELSE 0 END)      -- woke FROM deep = brutal
    + LEAST(16, GREATEST(0, (COALESCE(deep,105) - 120) / 4.0))      -- deep-heavy vs his ~105-min norm = heavy surfacing (finding #20)
    + GREATEST(0, (COALESCE(sh,9) - 9.5) * 4)                       -- oversleep grogginess
    + GREATEST(0, (7 - COALESCE(sh,9)) * 5);                        -- short-sleep grogginess
  RETURN NEXT;
END;$function$;

-- ==== should_wake_now (findings #21, #22) ====
CREATE OR REPLACE FUNCTION public.should_wake_now(p_user_id uuid, p_win_start timestamp with time zone, p_win_end timestamp with time zone, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(wake boolean, wake_score integer, deep_prob numeric, reason text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE dp numeric; dp_prev numeric;
BEGIN
  dp := current_deep_probability(p_user_id, p_at);
  deep_prob := dp;
  wake_score := CASE WHEN dp IS NULL THEN NULL ELSE ROUND(100*(1-dp)) END;

  IF p_at >= p_win_end THEN
    -- backstop / force-wake: report a defined "forced" readiness, mirroring
    -- should_wake_now_alcohol, instead of a deep-sleep-derived ~10 or NULL (finding #21).
    wake := true;  wake_score := 100; deep_prob := NULL;
    reason := '⏰ deadline reached — waking now';
  ELSIF p_at < p_win_start THEN
    wake := false; reason := 'before wake window';
  ELSIF dp IS NULL THEN
    wake := false; reason := 'no live data';
  ELSIF dp < 0.40 THEN
    -- Require the light-sleep read to PERSIST (also light ~3 min earlier) so a
    -- single transient arousal right after deep sleep can't force an early
    -- wake (finding #22). Hold otherwise; the deadline branch is the backstop.
    dp_prev := current_deep_probability(p_user_id, p_at - interval '3 minutes');
    IF dp_prev IS NOT NULL AND dp_prev < 0.40 THEN
      wake := true;  reason := '🟢 light sleep (sustained) — ideal moment to wake';
    ELSE
      wake := false; reason := '🟡 light but not yet sustained — hold, recheck shortly';
    END IF;
  ELSE
    wake := false; reason := '🛑 deep sleep — hold, recheck shortly';
  END IF;
  RETURN NEXT;
END;$function$;

-- ==== trigger_health_engine_on_wakeup (finding #19) -- DROP dead no-op ====
DROP TRIGGER IF EXISTS health_engine_wakeup_trigger ON public.brain_dumps;
DROP FUNCTION IF EXISTS public.trigger_health_engine_on_wakeup();

-- ============================================================================
-- GROUP: alcohol
-- ============================================================================
-- ============================================================
-- Migration v153 — cluster-5 ALCOHOL fixes (audit #10/#11/#12/#34/#35/#36)
-- Deployed live via /pg/query. is_alcohol_mode unchanged (fix inherited from detector).
-- ============================================================

CREATE OR REPLACE FUNCTION public.detect_overnight_alcohol(p_user_id uuid, p_target_date date, p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  -- v153 (audit alcohol #10/#11/#12/#34/#35) — rebuilt from the v137 hard-AND gate.
  -- The v137 detector averaged raw HR over a fixed 01:00-07:00 clock window (no sleep
  -- filter) and fired on avg_hr>base+20 AND avg_hrv<32. It MISSED moderate drink nights
  -- (Fabi's sober HRV baseline is ~50; moderate drinking only suppresses HRV to the mid-
  -- 30s, never below the absolute 32) and FALSE-FIRED on sober but sleepless nights
  -- (the raw clock average caught awake HR). Ground truth: it missed 2026-06-14 (a manual
  -- drink night) and fired on 2026-04-25 (a 1.2h-sleep awake night).
  --
  -- v153 rewrite:
  --  #11 asleep-only: aggregate over ASLEEP samples (sleep_stage <> 'awake') in the
  --      window, and require a real amount of asleep sleep so pure-awake nights can't
  --      fire. NOTE: alcohol CRUSHES sleep, so real drink nights only log ~160-180 asleep
  --      min. A 240-min floor (as the audit suggested) would null exactly the nights we
  --      must catch, so the floor is 120 min — enough to reject awake nights (0 asleep
  --      min) without rejecting the crushed-but-real drink nights.
  --  #12 window: extended to (target-1) 22:00 -> target 07:00 to capture early sleep
  --      onset after evening drinking, plus a separate 21:00-01:00 EVENING window used
  --      as the heat-vs-booze discriminator below.
  --  #10 personal-relative + soft vote: replaced the absolute avg_hrv<32 with a 2-of-3
  --      soft vote against Fabi's OWN recent-sober baselines (HR elevated, HRV suppressed,
  --      deep-sleep crushed) so moderate nights pass.
  --  #35 heat separation: the audit's core-floor veto (min_hr > base+8) would have
  --      false-negatived moderate nights whose CORE floor recovers (06-14 min_hr 52,
  --      06-05 min_hr 54 both dip near base). Instead the EVENING HR FLOOR is the heat
  --      separator: alcohol holds the evening HR floor UP all night (drink eve floors
  --      72/79/87) while heat lets it DIP (heat eve floors 65/69). eve_min_hr > base+18
  --      cleanly separates them without touching the moderate-night core floor.
  --  #34 sober baseline de-pollution: the base_* medians below exclude manual_drinking
  --      AND detector-persisted (alcohol_impact NOT NULL) nights so booze can't drift the
  --      baseline upward and desensitise the detector.
  -- Validated over 110 nights (2026-03-22..07-09): fires ONLY on 06-05, 06-13 (confirmed)
  -- and 06-14 (manual), rejecting every heat/awake night. 06-19 (a manual night with NO
  -- overnight OR evening signature) remains undetectable — no signal exists to catch it.
  core_start timestamptz := ((p_target_date - 1)::text || ' 22:00:00')::timestamp AT TIME ZONE p_user_tz;
  core_end   timestamptz := (p_target_date::text       || ' 07:00:00')::timestamp AT TIME ZONE p_user_tz;
  eve_start  timestamptz := ((p_target_date - 1)::text || ' 21:00:00')::timestamp AT TIME ZONE p_user_tz;
  eve_end    timestamptz := (p_target_date::text       || ' 01:00:00')::timestamp AT TIME ZONE p_user_tz;
  asleep_min bigint;
  min_hr     numeric;
  avg_hr     numeric;
  avg_hrv    numeric;
  deep_min   bigint;
  eve_n      bigint;
  eve_min_hr numeric;
  base_rhr   numeric;
  base_hrv   numeric;
  base_deep  numeric;
  core_votes int;
BEGIN
  -- Core sleep window, ASLEEP samples only.
  SELECT count(DISTINCT date_trunc('minute', recorded_at)),
         MIN(heart_rate), AVG(heart_rate), AVG(hrv_rmssd),
         count(DISTINCT date_trunc('minute', recorded_at)) FILTER (WHERE sleep_stage = 'deep')
    INTO asleep_min, min_hr, avg_hr, avg_hrv, deep_min
  FROM realtime_health
  WHERE user_id = p_user_id
    AND recorded_at >= core_start
    AND recorded_at <  core_end
    AND heart_rate IS NOT NULL AND heart_rate > 30
    AND sleep_stage IS NOT NULL AND sleep_stage <> 'awake';

  -- Confidence floor: reject awake / no-real-sleep nights (kills the 04-25 false positive).
  IF asleep_min IS NULL OR asleep_min < 120 OR avg_hr IS NULL OR avg_hrv IS NULL THEN
    RETURN false;
  END IF;

  -- Evening window (all samples): the HR floor that separates booze from heat.
  SELECT MIN(heart_rate), count(DISTINCT date_trunc('minute', recorded_at))
    INTO eve_min_hr, eve_n
  FROM realtime_health
  WHERE user_id = p_user_id
    AND recorded_at >= eve_start
    AND recorded_at <  eve_end
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  -- User's own recent-SOBER baselines (last 21 nights), excluding nights flagged alcohol
  -- (persisted or manual) or excluded, so booze never drifts the baseline upward (#34).
  SELECT COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY resting_hr)     FILTER (WHERE resting_hr     IS NOT NULL), 50),
         COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_avg)        FILTER (WHERE hrv_avg        IS NOT NULL), 50),
         COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY deep_sleep_min) FILTER (WHERE deep_sleep_min IS NOT NULL), 110)
    INTO base_rhr, base_hrv, base_deep
  FROM health_metrics hm
  WHERE hm.user_id = p_user_id
    AND hm.metric_date < p_target_date
    AND hm.metric_date >= p_target_date - 21
    AND COALESCE(hm.excluded, false) = false
    AND hm.alcohol_impact IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM alcohol_flags af
      WHERE af.user_id = p_user_id AND af.flag_date = hm.metric_date AND af.manual_drinking
    );

  -- 2-of-3 soft vote against Fabi's own sober baseline (#10).
  core_votes :=
      (CASE WHEN avg_hrv  < base_hrv  * 0.80 THEN 1 ELSE 0 END)   -- HRV suppressed
    + (CASE WHEN deep_min < base_deep * 0.5  THEN 1 ELSE 0 END)   -- deep sleep crushed
    + (CASE WHEN avg_hr   > base_rhr  + 12   THEN 1 ELSE 0 END);  -- sleeping HR elevated

  RETURN
    -- Moderate/typical: 2 sleep signals + the evening HR floor held up (heat separator, #35/#12)
    ( core_votes >= 2
      AND eve_n IS NOT NULL AND eve_n >= 30
      AND eve_min_hr IS NOT NULL AND eve_min_hr > base_rhr + 18 )
    -- Near-blackout safety net: all 3 sleep signals + HRV floored + HR floor held up,
    -- fires even if evening strap data is missing. Verified no sober/heat night reaches this.
    OR ( core_votes >= 3
         AND avg_hrv < base_hrv * 0.55
         AND min_hr  > base_rhr + 12 );
END;
$function$;

-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.refresh_alcohol_priors(p_user_id uuid, p_lookback_days integer DEFAULT 120)
 RETURNS TABLE(hr_offset numeric, drunk_sleep numeric, drunk_deep numeric, n_alcohol integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE drunk_rhr numeric; sober_rhr numeric; off numeric; dsleep numeric; ddeep numeric; ncnt int;
BEGIN
  -- v153 (audit #34): partition nights by (detector OR manual_drinking), not detector
  -- alone. Fabi's manually-confirmed drink nights (alcohol_flags.manual_drinking) were
  -- previously counted as SOBER in the sober_rhr median, drifting the sober baseline up
  -- and biasing the learned alcohol_hr_offset down (desensitising the detector). Now a
  -- manual OR detected drink night lands in the DRUNK partition and is excluded from the
  -- sober baseline. Return shape unchanged.
  WITH nights AS (
    SELECT d::date dt,
      ( detect_overnight_alcohol(p_user_id, d::date, 'Europe/Berlin')
        OR EXISTS (SELECT 1 FROM alcohol_flags af
                    WHERE af.user_id = p_user_id AND af.flag_date = d::date AND af.manual_drinking)
      ) alc
    FROM generate_series(CURRENT_DATE - p_lookback_days, CURRENT_DATE - 1, '1 day') d
  )
  SELECT
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.resting_hr)     FILTER (WHERE n.alc),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.resting_hr)     FILTER (WHERE NOT n.alc),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.sleep_hours)    FILTER (WHERE n.alc),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.deep_sleep_min) FILTER (WHERE n.alc),
    count(*) FILTER (WHERE n.alc)
  INTO drunk_rhr, sober_rhr, dsleep, ddeep, ncnt
  FROM nights n
  JOIN health_metrics hm ON hm.user_id=p_user_id AND hm.metric_date=n.dt
  WHERE hm.sleep_hours > 0;

  IF ncnt >= 3 AND drunk_rhr IS NOT NULL AND sober_rhr IS NOT NULL THEN
    off := GREATEST(0, drunk_rhr - sober_rhr);
    PERFORM seed_alcohol_priors(p_user_id);                          -- ensure row exists
    PERFORM update_personal_prior(p_user_id, 'alcohol_hr_offset', off, 1.0);
  ELSE
    off := COALESCE((SELECT mu FROM personal_priors
                     WHERE user_id=p_user_id AND param='alcohol_hr_offset'), 10);
  END IF;

  hr_offset   := round(off::numeric, 1);
  drunk_sleep := round(dsleep::numeric, 1);
  drunk_deep  := round(ddeep::numeric);
  n_alcohol   := ncnt;
  RETURN NEXT;
END;$function$;

-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.plan_tonight_alcohol(p_user_id uuid, p_wake_deadline timestamp with time zone DEFAULT NULL::timestamp with time zone, p_prep_min integer DEFAULT 45, p_travel_min integer DEFAULT 0)
 RETURNS TABLE(alcohol_mode boolean, target_bedtime timestamp with time zone, target_wake timestamp with time zone, wake_window_start timestamp with time zone, wake_window_end timestamp with time zone, hard_backstop timestamp with time zone, target_sleep_h numeric, hr_floor numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  nstar numeric; floor_hr numeric; w_latest timestamptz; tw timestamptz;
  tz text := 'Europe/Berlin';
  tom date := (now() AT TIME ZONE 'Europe/Berlin')::date + 1;
  humane_min timestamptz; backstop timestamptz; parts text;
  alc boolean;
BEGIN
  -- v153 (audit #36): alcohol_mode was hardcoded true, so any DIRECT caller asking
  -- "is tonight an alcohol night?" always got the drunk-night 9am-earliest / 12:00-backstop
  -- schedule, even stone sober. Compute the REAL boolean for the target night (tom).
  -- (plan_tonight_auto already gates on is_alcohol_mode before calling this, so its
  -- routing is unaffected; this fixes the misleading boolean/plan for direct callers.)
  alc := is_alcohol_mode(p_user_id, tom);

  SELECT mu INTO nstar FROM personal_priors
   WHERE user_id=p_user_id AND param='alcohol_sleep_target_h';
  nstar := COALESCE(nstar, 9.0);
  floor_hr := alcohol_hr_floor(p_user_id);

  -- humane drunk-night earliest-consider wake = 09:00 Berlin; hard backstop = 12:00.
  humane_min := ((tom::timestamp) + interval '9 hours')  AT TIME ZONE tz;
  backstop   := ((tom::timestamp) + interval '12 hours') AT TIME ZONE tz;

  IF p_wake_deadline IS NOT NULL THEN
    -- a real commitment: maximize sleep up to it (can't skip a flight), flag the cost
    w_latest := p_wake_deadline - make_interval(mins => p_prep_min + p_travel_min);
    tw := w_latest;
    backstop := w_latest;                            -- the commitment IS the hard stop
    parts := format('🍷 Alcohol mode + a hard %s commitment. Sleeping you to the last safe minute (%s) — no earlier. Expect low recovery; water + salt before bed, no caffeine before noon.',
                    to_char(p_wake_deadline AT TIME ZONE tz,'HH24:MI'),
                    to_char(tw AT TIME ZONE tz,'HH24:MI'));
  ELSE
    -- NO commitment: no early alarm at all. The back-half rebound is sacred.
    tw := humane_min;
    parts := format('🍷 Alcohol mode, nothing hard tomorrow — no early alarm. Smart-wake only starts watching at %s, hard backstop %s. Your deep sleep rebounds in the back half of the night as it clears; cutting that short is exactly what wrecked you before, so we don''t.',
                    to_char(humane_min AT TIME ZONE tz,'HH24:MI'),
                    to_char(backstop   AT TIME ZONE tz,'HH24:MI'));
  END IF;

  -- Sober night: return the honest boolean and a sober note so a direct caller isn't
  -- shown a drunk-night narrative. The schedule fields stay populated (shape preserved);
  -- callers that gate on alcohol_mode=false should defer to the normal sober planner
  -- (plan_tonight_from_calendar) — which is exactly what plan_tonight_auto does.
  IF NOT alc THEN
    parts := '🌙 Not an alcohol night — use your normal wake plan (plan_tonight_from_calendar). This alcohol schedule is informational only.';
  END IF;

  alcohol_mode      := alc;
  target_wake       := tw;
  wake_window_start := tw;
  wake_window_end   := backstop;
  hard_backstop     := backstop;
  target_sleep_h    := nstar;
  hr_floor          := floor_hr;
  target_bedtime    := tw - make_interval(secs => round(nstar*3600)::int);  -- informational
  note := parts;
  RETURN NEXT;
END;$function$;

-- ============================================================================
-- GROUP: pipeline
-- ============================================================================
-- ========== FINDING #14: cleanup_old_realtime_health (7d -> 90d retention, keep UNSCHEDULED) ==========
CREATE OR REPLACE FUNCTION public.cleanup_old_realtime_health()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
    -- Retention raised from 7 -> 90 days (audit #14): 90d is the longest downstream
    -- lookback (baselines/correlation jobs), so this is non-destructive to every consumer
    -- even if it is ever wired to cron. History backfills land rows only within the last
    -- few days, so a 90-day cutter cannot race them. Function remains UNSCHEDULED.
    DELETE FROM realtime_health
    WHERE recorded_at < now() - INTERVAL '90 days';
END;
$function$;

-- ========== FINDING #38: refresh_current_state_from_realtime (baseline_resting_hr = p05, not AVG) ==========
CREATE OR REPLACE FUNCTION public.refresh_current_state_from_realtime()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_user UUID := NEW.user_id;
  v_now TIMESTAMPTZ := NEW.recorded_at;

  v_last_15m_start TIMESTAMPTZ := v_now - INTERVAL '15 minutes';
  v_last_1h_start  TIMESTAMPTZ := v_now - INTERVAL '1 hour';
  v_last_7d_start  TIMESTAMPTZ := v_now - INTERVAL '7 days';

  v_cog_15m NUMERIC;
  v_cog_label TEXT;
  v_illness_1h NUMERIC;
  v_baseline_hrv NUMERIC;
  v_baseline_rhr INTEGER;
  v_baseline_rr NUMERIC;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.current_state
    WHERE user_id = v_user AND updated_at > v_now - INTERVAL '5 seconds'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT AVG(cognitive_capacity) INTO v_cog_15m
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_15m_start
    AND cognitive_capacity IS NOT NULL AND cognitive_capacity > 0;

  SELECT cognitive_label INTO v_cog_label
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_15m_start
    AND cognitive_label IS NOT NULL
  GROUP BY cognitive_label ORDER BY COUNT(*) DESC LIMIT 1;

  SELECT MAX(illness_risk) INTO v_illness_1h
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_1h_start
    AND illness_risk IS NOT NULL;

  -- audit #38: resting HR is the LOW of sleeping HR, not its average. AVG(sleeping HR)
  -- ran ~10bpm high (59 vs real ~49), masking RHR elevation in illness/stress/spiral logic.
  -- Use the 5th percentile of sleeping HR to match how resting HR is defined elsewhere.
  SELECT AVG(hrv_rmssd),
         (percentile_cont(0.05) WITHIN GROUP (ORDER BY heart_rate))::INTEGER,
         AVG(respiratory_rate)
  INTO v_baseline_hrv, v_baseline_rhr, v_baseline_rr
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_7d_start
    AND sleep_stage IN ('deep','rem','light')
    AND hrv_rmssd IS NOT NULL AND hrv_rmssd > 0;

  INSERT INTO public.current_state (
    user_id, updated_at,
    strap_connected, last_ble_sample_at, battery_pct,
    current_hr, current_hrv_rmssd, current_sdnn, current_dfa_alpha1, current_respiratory_rate,
    current_cognitive_capacity, current_cognitive_label, current_readiness,
    current_illness_risk, current_sleep_stage,
    current_hmm_state, current_hmm_state_id,
    baseline_hrv_avg, baseline_resting_hr, baseline_respiratory_rate,
    current_activity_state
  ) VALUES (
    v_user, v_now,
    TRUE, v_now, NEW.battery_pct,
    NEW.heart_rate, NEW.hrv_rmssd, NEW.sdnn, NEW.dfa_alpha1, NEW.respiratory_rate,
    v_cog_15m::INTEGER, v_cog_label, NEW.readiness,
    v_illness_1h, NEW.sleep_stage,
    NEW.hmm_state, NEW.hmm_state_id,
    v_baseline_hrv, v_baseline_rhr, v_baseline_rr,
    CASE
      WHEN NEW.sleep_stage IN ('deep','rem','light') THEN 'sleeping'
      WHEN NEW.heart_rate > 110 THEN 'active'
      ELSE 'resting'
    END
  )
  ON CONFLICT (user_id) DO UPDATE SET
    updated_at = EXCLUDED.updated_at,
    strap_connected = TRUE,
    last_ble_sample_at = EXCLUDED.last_ble_sample_at,
    battery_pct = EXCLUDED.battery_pct,
    current_hr = EXCLUDED.current_hr,
    current_hrv_rmssd = EXCLUDED.current_hrv_rmssd,
    current_sdnn = COALESCE(EXCLUDED.current_sdnn, current_state.current_sdnn),
    current_dfa_alpha1 = COALESCE(EXCLUDED.current_dfa_alpha1, current_state.current_dfa_alpha1),
    current_respiratory_rate = COALESCE(EXCLUDED.current_respiratory_rate, current_state.current_respiratory_rate),
    current_cognitive_capacity = COALESCE(EXCLUDED.current_cognitive_capacity, current_state.current_cognitive_capacity),
    current_cognitive_label = COALESCE(EXCLUDED.current_cognitive_label, current_state.current_cognitive_label),
    current_readiness = COALESCE(EXCLUDED.current_readiness, current_state.current_readiness),
    current_illness_risk = COALESCE(EXCLUDED.current_illness_risk, current_state.current_illness_risk),
    current_sleep_stage = EXCLUDED.current_sleep_stage,
    current_hmm_state = COALESCE(EXCLUDED.current_hmm_state, current_state.current_hmm_state),
    current_hmm_state_id = COALESCE(EXCLUDED.current_hmm_state_id, current_state.current_hmm_state_id),
    baseline_hrv_avg = COALESCE(EXCLUDED.baseline_hrv_avg, current_state.baseline_hrv_avg),
    baseline_resting_hr = COALESCE(EXCLUDED.baseline_resting_hr, current_state.baseline_resting_hr),
    baseline_respiratory_rate = COALESCE(EXCLUDED.baseline_respiratory_rate, current_state.baseline_respiratory_rate),
    current_activity_state = EXCLUDED.current_activity_state;

  RETURN NEW;
END;
$function$;

-- ========== FINDINGS #13/#37/#39/#40 + Rank 9: recompute_health_metrics ==========
CREATE OR REPLACE FUNCTION public.recompute_health_metrics(p_user_id uuid, p_target_date date DEFAULT NULL::date)
 RETURNS health_metrics
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  target_date         date;
  win                 record;
  s_score             numeric;
  r_score             numeric;
  result_row          health_metrics;
  has_open_alert      boolean;
  has_recent_backfill boolean;
  is_alcohol          boolean;
  st_clean            numeric;
  is_low_conf         boolean;
BEGIN
  target_date := COALESCE(p_target_date, (now() AT TIME ZONE 'Europe/Berlin')::date);

  -- v106: detect alcohol once, reuse for both sleep window + impact stamp
  SELECT detect_overnight_alcohol(p_user_id, target_date) INTO is_alcohol;

  -- v152: cleaned daily skin temp (physiological gate + cross-day slew reject)
  st_clean := clean_skin_temp_day(p_user_id, target_date);

  -- 1. Detect sleep window (alcohol-aware via v106)
  SELECT * INTO win FROM detect_sleep_window(p_user_id, target_date);

  -- audit #13: route to the NO-SCORE path ONLY when there is genuinely no usable window
  -- (no window at all, or <60 measured asleep min). A short-but-real window is now SCORED
  -- and stamped readiness_level='low_confidence' below, instead of being permanently blanked.
  IF win.o_sleep_start IS NULL OR COALESCE(win.o_asleep_min, 0) < 60 THEN
    -- ===== NO-SCORE PATH (no usable sleep window) =====
    -- v104: defer NULL-placeholder writes if a BLE sync is in flight.
    -- audit #37: bound the open-alert check to the last 3h so a single stuck-open alert
    -- can't defer this date forever (the backfill check is already 60-min bounded).
    SELECT EXISTS (
      SELECT 1 FROM ble_freshness_alerts
      WHERE user_id = p_user_id AND state = 'open'
        AND detected_at >= NOW() - INTERVAL '3 hours'
    ) INTO has_open_alert;

    SELECT EXISTS (
      SELECT 1 FROM bridge_logs
      WHERE user_id = p_user_id
        AND created_at >= NOW() - INTERVAL '60 minutes'
        AND (
          (key = 'history_sync_gap_check'   AND value::text LIKE '%decision=download%')
          OR key = 'history_sync_request_sent'
          OR key = 'history_sync_complete'
          OR key = 'history_sync_batch_start'
        )
    ) INTO has_recent_backfill;

    IF has_open_alert OR has_recent_backfill THEN
      RAISE NOTICE 'recompute_health_metrics: sync in flight for %, deferring (alert=% backfill=%)',
        p_user_id, has_open_alert, has_recent_backfill;

      SELECT * INTO result_row FROM health_metrics
      WHERE user_id = p_user_id AND metric_date = target_date;
      -- audit #40: don't emit an all-NULL composite (NULL PK) when no row exists yet.
      IF result_row.metric_date IS NULL THEN
        RETURN NULL;
      END IF;
      RETURN result_row;
    END IF;

    -- Insert empty placeholder if no row exists yet, but never overwrite a real one.
    -- v152: skin_temp is pg-owned; refresh it here too.
    -- audit #39: on this low-confidence path NEVER clear an existing real alcohol flag --
    -- only SET 1.0 when detected, otherwise preserve whatever is stored (detect_overnight_alcohol
    -- has a known evening-peak false-negative, so a low-sleep re-run must not flip a real 1.0 to
    -- NULL). Guard skin_temp with COALESCE so a NULL clean value can't wipe a good stored one.
    INSERT INTO health_metrics (user_id, metric_date, source, alcohol_impact, skin_temp)
    VALUES (p_user_id, target_date, 'pg_recompute', CASE WHEN is_alcohol THEN 1.0 ELSE NULL END, st_clean)
    ON CONFLICT (user_id, metric_date) DO UPDATE SET
      alcohol_impact = CASE WHEN is_alcohol THEN 1.0 ELSE health_metrics.alcohol_impact END,
      skin_temp      = COALESCE(EXCLUDED.skin_temp, health_metrics.skin_temp);

    SELECT * INTO result_row FROM health_metrics
    WHERE user_id = p_user_id AND metric_date = target_date;
    RETURN result_row;
  END IF;

  -- ===== SCORED PATH (usable window: >=60 measured asleep min) =====
  -- audit #13: >=240 asleep min keeps full green/yellow/red; 60..239 is scored but stamped
  -- low_confidence so the UI can dim it, instead of leaving the night permanently blank.
  is_low_conf := COALESCE(win.o_asleep_min, 0) < 240;

  -- 2. Compute scores
  s_score := compute_sleep_score(
    win.o_total_min, win.o_asleep_min, win.o_deep_min, win.o_rem_min, win.o_efficiency_pct
  );
  -- Rank 9 wiring: pass target_date so a historical recompute scores against the target day's
  -- 30-day window (not today's) per the shared compute_recovery_score(...,p_date) contract.
  r_score := compute_recovery_score(
    p_user_id, win.o_hrv_avg, win.o_resting_hr, s_score, target_date
  );

  -- 3. Upsert (alcohol_impact stamp + v152 cleaned skin_temp)
  INSERT INTO health_metrics (
    user_id, metric_date, source,
    sleep_start, sleep_end, sleep_hours,
    deep_sleep_min, rem_sleep_min, light_sleep_min, awake_min,
    sleep_efficiency_pct, sleep_score, recovery_score,
    hrv_avg, resting_hr,
    readiness_level, readiness_score, alcohol_impact, skin_temp
  )
  VALUES (
    p_user_id, target_date, 'pg_recompute',
    win.o_sleep_start, win.o_sleep_end,
    ROUND(win.o_asleep_min / 60.0, 1),
    win.o_deep_min, win.o_rem_min, win.o_light_min, win.o_awake_min,
    win.o_efficiency_pct, s_score, r_score,
    win.o_hrv_avg, win.o_resting_hr,
    CASE WHEN is_low_conf THEN 'low_confidence'
         WHEN r_score >= 67 THEN 'green'
         WHEN r_score >= 34 THEN 'yellow'
         ELSE 'red' END,
    r_score,
    CASE WHEN is_alcohol THEN 1.0 ELSE NULL END,
    st_clean
  )
  ON CONFLICT (user_id, metric_date) DO UPDATE SET
    source = 'pg_recompute',
    sleep_start = EXCLUDED.sleep_start,
    sleep_end = EXCLUDED.sleep_end,
    sleep_hours = EXCLUDED.sleep_hours,
    deep_sleep_min = EXCLUDED.deep_sleep_min,
    rem_sleep_min = EXCLUDED.rem_sleep_min,
    light_sleep_min = EXCLUDED.light_sleep_min,
    awake_min = EXCLUDED.awake_min,
    sleep_efficiency_pct = EXCLUDED.sleep_efficiency_pct,
    sleep_score = EXCLUDED.sleep_score,
    recovery_score = EXCLUDED.recovery_score,
    hrv_avg = EXCLUDED.hrv_avg,
    resting_hr = EXCLUDED.resting_hr,
    readiness_level = EXCLUDED.readiness_level,
    readiness_score = EXCLUDED.readiness_score,
    -- audit #39: only downgrade alcohol on HIGH-confidence sober evidence; a low_confidence
    -- re-run must never clear an existing real 1.0.
    alcohol_impact = CASE WHEN is_low_conf
                          THEN CASE WHEN is_alcohol THEN 1.0 ELSE health_metrics.alcohol_impact END
                          ELSE EXCLUDED.alcohol_impact END,
    -- audit #39: never let a NULL clean value wipe a good stored skin_temp.
    skin_temp = COALESCE(EXCLUDED.skin_temp, health_metrics.skin_temp);

  SELECT * INTO result_row FROM health_metrics
  WHERE user_id = p_user_id AND metric_date = target_date;
  RETURN result_row;
END;
$function$;

-- ============================================================================
-- POST-DEPLOY DATA OPS (applied live, for the record)
-- ============================================================================
-- [sleep] RESEED: personal_priors.optimal_sleep_hours re-seeded from mu=10.06 (rigid accumulated posterior, tau2=0.009, n_obs=39) to mu=8.0 (tau2 reset to 1.0, n_obs=1, prior_mu=8). A single refresh_optimal_sleep_prior() call could NOT move the posterior because update_personal_prior is a precision-weighted Kalman update dominated by 39 historical ~10h observations — so the accumulator was reset directly to the fixed dose-response knee (8h, which the corrected function now returns). The now-fixed nightly refresh keeps it at ~8. Verified: base used by compute_sleep_debt and target_sleep_duration is now 8.0.
-- [body-battery] RESEED: recompute_body_battery(user, 4) re-seeded body_battery_anchor for 2026-07-06..09 to the canonical morning charge: 07-06 52.3→98.8, 07-07 62.8→100, 07-08 61.9→91.4, 07-09 →88.0 (each now exactly equals clamp(100+daily_adjustment), reconciling with the live path per #31). The end-to-end production cron path refresh_live_body_battery also wrote today's body_battery (2026-07-10)=100 — normal every-15-min live behavior, not a backfill. Full 120-day anchor history was intentionally NOT re-run (left to the central Verify re-derivation), though the next smart_alarm_learn run will canonicalize the rest cheaply.
-- [alcohol] RESEED: personal_priors.alcohol_hr_offset: ran refresh_alcohol_priors(uid,120) ONCE (its normal learning operation, also what smart_alarm_learn calls on schedule) to prove the deployed fix executes and to let it re-learn from the corrected (detector OR manual) partition. Result damped by the existing n_obs: mu 10.33 -> 10.19, n_obs 35 -> 36, updated_at 2026-07-09 23:56 UTC. No wild swing, well within band. alcohol_sleep_target_h left untouched (mu 9.0, n_obs 0). No health_metrics rows re-seeded (that is the Verify phase's central re-derive).
-- [pipeline] RESEED: Re-ran recompute_health_metrics on the two nights #13 cited as permanently-blanked, filling their NULL scores: 2026-06-15 (blank -> recovery_score 49, sleep_score 52, readiness_level='low_confidence', 190 asleep min, skin_temp preserved 35.6) and 2026-05-21 (blank -> recovery_score 21, sleep_score 71, readiness_level='red', 312 asleep min = high-confidence, skin_temp 35.7). 2026-07-06 was also re-run as a high-confidence regression check and came back unchanged (recovery 100 green, sleep 90). No broader backfill was run — all other history is left for the central Verify re-derivation.
