-- migration v120_sleep_wake_trim.sql
-- Morning WAKE trim for detect_sleep_window. Lying in bed awake after waking
-- (HR/HRV climbing but under the absolute wake_thresh 79) was counted as
-- light/REM, inflating duration (10.4h real ~8.6h) + REM (200m). Added a
-- terminal-elevation wake anchor: cut at the first minute (>=4h in) whose run
-- to the island END stays elevated vs the night floor. Normal nights preserved.

CREATE OR REPLACE FUNCTION public.detect_sleep_window(p_user_id uuid, p_target_date date, p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS TABLE(o_sleep_start timestamp with time zone, o_sleep_end timestamp with time zone, o_total_min integer, o_asleep_min integer, o_deep_min integer, o_rem_min integer, o_light_min integer, o_awake_min integer, o_efficiency_pct integer, o_hrv_avg numeric, o_resting_hr integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  win_start timestamptz := ((p_target_date - 1)::text || ' 19:00:00')::timestamp AT TIME ZONE p_user_tz;
  win_end   timestamptz := (p_target_date::text     || ' 12:00:00')::timestamp AT TIME ZONE p_user_tz;
  -- v106: thresholds become variable — bumped on alcohol nights.
  sleep_thresh int := 65;
  wake_thresh  int := 79;
  deep_ceiling int := 54;
  rem_sd_min   numeric := 3.0;
  bridge_max   int := 20;
  rhr_floor    int := 35;
  resp_thresh  numeric := 21.0;   -- v109: couch-lead-in trim. couch>=21.2, sleep<=19.7
  is_alcohol   boolean := false;
BEGIN
  -- v106: alcohol-aware threshold bumps. Single-user calibration —
  -- Fabi's sober sleeping HR is 48-52, drunk is 60-69, so bump by ~10 bpm.
  SELECT detect_overnight_alcohol(p_user_id, p_target_date, p_user_tz) INTO is_alcohol;
  IF is_alcohol THEN
    sleep_thresh := 75;
    wake_thresh  := 89;
    deep_ceiling := 62;
    rhr_floor    := 40;
    resp_thresh  := 99;   -- v109: disable couch trim on alcohol nights (drunk breathing runs high)
  END IF;

  RETURN QUERY
  WITH minute_buckets AS (
    SELECT
      date_trunc('minute', recorded_at) AS m_ts,
      AVG(heart_rate)::numeric AS hr_avg,
      stddev_samp(heart_rate)::numeric AS hr_sd,
      AVG(hrv_rmssd)::numeric AS hrv_avg,
      AVG(respiratory_rate) FILTER (WHERE respiratory_rate > 0)::numeric AS resp_avg
    FROM realtime_health
    WHERE user_id = p_user_id
      AND recorded_at >= win_start
      AND recorded_at <  win_end
      AND heart_rate IS NOT NULL
      AND heart_rate > 30
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
      CASE WHEN hr_smooth < sleep_thresh THEN 1 ELSE 0 END AS raw_is_sleep
    FROM smoothed
  ),
  with_lag AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, raw_is_sleep,
      LAG(raw_is_sleep, 1, raw_is_sleep) OVER (ORDER BY m_ts) AS prev_is_sleep
    FROM flagged
  ),
  runs AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, raw_is_sleep,
      SUM(CASE WHEN raw_is_sleep != prev_is_sleep THEN 1 ELSE 0 END)
        OVER (ORDER BY m_ts) AS run_id
    FROM with_lag
  ),
  run_lengths AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, raw_is_sleep, run_id,
      COUNT(*) OVER (PARTITION BY run_id) AS run_length
    FROM runs
  ),
  bridged AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN raw_is_sleep = 1 THEN 1
        WHEN run_length < bridge_max THEN 1
        ELSE 0
      END AS is_sleep
    FROM run_lengths
  ),
  islands AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, is_sleep,
      SUM(CASE WHEN is_sleep = 0 THEN 1 ELSE 0 END)
        OVER (ORDER BY m_ts) AS gap_id
    FROM bridged
  ),
  sleep_islands AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      gap_id - 1 AS island_id
    FROM islands
    WHERE is_sleep = 1
  ),
  longest_island AS (
    SELECT island_id
    FROM sleep_islands
    GROUP BY island_id
    ORDER BY COUNT(*) DESC
    LIMIT 1
  ),
  -- HR-only longest island, re-joined to smoothed to recover resp_smooth.
  island_minutes AS (
    SELECT s.m_ts, s.hr_avg, s.hr_sd, s.hrv_avg, s.hr_smooth, sm.resp_smooth
    FROM sleep_islands s
    JOIN longest_island li ON s.island_id = li.island_id
    JOIN smoothed sm ON sm.m_ts = s.m_ts
  ),
  -- v109: forward sustained-low-resp fraction over the next 20 min. A brief
  -- couch resp dip (movement confuses the RR estimator into a low spike) is
  -- NOT sustained, so it never anchors; real sleep is a long low-resp run.
  island_fwd AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      AVG(CASE WHEN resp_smooth < resp_thresh THEN 1.0 ELSE 0.0 END)
        FILTER (WHERE resp_smooth IS NOT NULL)
        OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 19 FOLLOWING) AS fwd_low_frac
    FROM island_minutes
  ),
  -- real sleep onset = first minute whose next 20 min are >=60% low-resp.
  -- Fall back to island start if nothing qualifies (resp-less night).
  onset_anchor AS (
    SELECT COALESCE(
      MIN(m_ts) FILTER (WHERE fwd_low_frac >= 0.6 AND hr_smooth < sleep_thresh),
      MIN(m_ts)
    ) AS real_onset
    FROM island_fwd
  ),
  -- Trim the leading couch edge; everything from real_onset on is preserved.
  sleep_minutes AS (
    SELECT im.m_ts, im.hr_avg, im.hr_sd, im.hrv_avg, im.hr_smooth
    FROM island_minutes im, onset_anchor oa
    WHERE im.m_ts >= oa.real_onset
  ),
  -- v120: morning WAKE trim (symmetric to the couch-onset trim). Lying in bed
  -- awake after waking — HR/HRV climbing but still under the absolute wake_thresh
  -- — was counted as light/REM, inflating duration (10.4h) and REM (200m). Cut at
  -- the real final wake: first minute (>=4h into sleep) whose next 20 min stay
  -- elevated relative to the night's OWN floor (adapts to sober vs drunk nights).
  night_floor AS (
    SELECT percentile_cont(0.10) WITHIN GROUP (ORDER BY hr_smooth) AS floor_hr
    FROM sleep_minutes
  ),
  -- TERMINAL elevation: fraction of minutes from here to the island END that are
  -- elevated. Mid-night light-sleep blips fail (deep sleep follows -> low tail
  -- fraction); only the real morning wake (stays up to the end) qualifies. This
  -- is what stops it butchering normal nights.
  wake_tail AS (
    SELECT sm.m_ts, sm.hr_smooth, nf.floor_hr,
      AVG(CASE WHEN sm.hr_smooth >= nf.floor_hr + 9 THEN 1.0 ELSE 0.0 END)
        OVER (ORDER BY sm.m_ts ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS tail_hi,
      COUNT(*)
        OVER (ORDER BY sm.m_ts ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS tail_n
    FROM sleep_minutes sm CROSS JOIN night_floor nf
  ),
  wake_anchor AS (
    SELECT COALESCE(
      MIN(m_ts) FILTER (
        WHERE tail_hi >= 0.55 AND tail_n >= 15
          AND hr_smooth >= floor_hr + 9
          AND m_ts >= (SELECT MIN(m_ts) FROM sleep_minutes) + interval '4 hours'
      ),
      (SELECT MAX(m_ts) FROM sleep_minutes) + interval '1 minute'
    ) AS real_wake
    FROM wake_tail
  ),
  core_minutes AS (
    SELECT sm.* FROM sleep_minutes sm, wake_anchor wa
    WHERE sm.m_ts < wa.real_wake
  ),
  classified AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN hr_smooth > wake_thresh THEN 'awake'
        WHEN hr_smooth < deep_ceiling AND hr_sd < 3 THEN 'deep'
        WHEN hr_sd > rem_sd_min THEN 'rem'
        ELSE 'light'
      END AS stage
    FROM core_minutes
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
      percentile_cont(0.05) WITHIN GROUP (ORDER BY hr_avg)
        FILTER (WHERE hr_avg > rhr_floor)::numeric AS rhr_p5
    FROM classified
  )
  SELECT
    w_start,
    w_end,
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
$function$
