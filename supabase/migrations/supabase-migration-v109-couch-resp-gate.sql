-- migration v109_couch_resp_gate.sql
--
-- Stop counting couch-chilling as sleep — WITHOUT shredding real nights.
--
-- Problem (Fabi, 2026-06-02): "I was watching a movie on the couch, very
-- sleepy, went to bed around 12 — but the app says I went to bed at 10."
-- Root cause: raw_is_sleep was HR-ONLY (hr_smooth < sleep_thresh=65). Lying
-- still on the couch his HR drifts to 62-68, dips under 65, those minutes
-- flag as sleep and get absorbed into the sleep island -> onset ~2.5h early.
-- Confirmed: 06-01 function onset 22:14 vs TRUE 00:45 (resp crashed 23->18,
-- pct-low-resp 26%->100% exactly there); 06-03 22:21 vs real ~02:00.
--
-- The discriminator: RESPIRATORY RATE (autonomic — can't fake by lying
-- still). Couch breathing smooths to 21-24; real sleep to 17-19.
--   NOTE: realtime_health.respiratory_rate uses 24.0 as a could-not-estimate
--   SENTINEL (26% of deep-sleep minutes read exactly 24.0). Sentinels are
--   kept IN the smooth on purpose — their density tracks awake/movement.
--
-- FAILED FIRST ATTEMPT (do not reintroduce): gating raw_is_sleep per-minute
-- on resp fragmented every night — sentinel clusters mid-sleep broke the
-- island so longest-island picked a short fragment (615->271 min etc).
--
-- WORKING FIX: keep island detection HR-ONLY (night stays whole + bridged),
-- then TRIM THE LEADING COUCH EDGE. Onset moves forward to the first minute
-- that satisfies a SUSTAINED real-sleep test: the next 20 min are >=60%
-- low-breathing (15-min-smoothed resp < resp_thresh=21.0) AND that minute's
-- HR is already sleep-level (hr_smooth < sleep_thresh=65). Everything after
-- that anchor is preserved untouched, so mid-night REM/sentinel resp spikes
-- never fragment the night. Two guards beat the couch's movement artifacts:
--   * the 20-min/60% forward window ignores brief resp dips (a movement event
--     makes the RR estimator spit a low spike for a few min — not sustained);
--   * the HR guard rejects anchors sitting in couch/movement HR territory
--     (real sleep onset is low-resp AND low-HR together).
-- NULL-permissive: if nothing qualifies (resp missing / sentinel-only night)
-- it falls back to the full HR-only island — ZERO regression on resp-less
-- nights. Trim only ever moves onset LATER, never removes mid-sleep.
-- Tuning note: 20-min/0.6 is the validated sweet spot. 30-min/0.7 was tried
-- and rejected (regressed a clean night 00:47->02:15 while not improving the
-- artifact night) — do not tighten without re-running the 10-night harness.
--
-- Alcohol nights: resp_thresh := 99 (trim disabled) so v106's HR-bump
-- calibration is untouched (drunk breathing runs high).
--
-- UNCHANGED: HR smoothing (+-2min), bridge_max=20, island/longest-island,
-- stage classification, RHR p5, HRV mean, alcohol HR bumps, signature.

CREATE OR REPLACE FUNCTION public.detect_sleep_window(
  p_user_id uuid,
  p_target_date date,
  p_user_tz text DEFAULT 'Europe/Berlin'::text
)
RETURNS TABLE(
  o_sleep_start timestamp with time zone,
  o_sleep_end timestamp with time zone,
  o_total_min integer,
  o_asleep_min integer,
  o_deep_min integer,
  o_rem_min integer,
  o_light_min integer,
  o_awake_min integer,
  o_efficiency_pct integer,
  o_hrv_avg numeric,
  o_resting_hr integer
)
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
  classified AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN hr_smooth > wake_thresh THEN 'awake'
        WHEN hr_smooth < deep_ceiling AND hr_sd < 3 THEN 'deep'
        WHEN hr_sd > rem_sd_min THEN 'rem'
        ELSE 'light'
      END AS stage
    FROM sleep_minutes
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
$function$;

COMMENT ON FUNCTION public.detect_sleep_window IS
'v109 (2026-06-03). HR island detection + respiratory couch-lead-in TRIM. Sleep island found HR-only (whole night preserved + bridged), then onset moved forward to the first minute passing a sustained real-sleep test: next 20 min >=60% low-breathing (15-min-smoothed resp < 21.0) AND hr_smooth < 65. Trims couch-chilling (HR dips <65 but breathing stays 22-24) off the front without fragmenting mid-sleep; the forward-window + HR guard reject brief movement-artifact resp dips. NULL-permissive (resp-less night = full HR-only island, zero regression). resp 24.0 = could-not-estimate sentinel, kept in smooth as awake-density proxy. Alcohol nights disable the trim (resp_thresh=99) to preserve v106. Validated on 10 nights: clean nights unchanged, couch nights 06-02 00:39->01:26 and 06-03 22:21->00:41. Replaces a failed per-minute-gate attempt that shredded nights via mid-sleep sentinel clusters.';
