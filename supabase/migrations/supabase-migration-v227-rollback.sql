-- v227 rollback - restores the backfill HRV values, drops the guard trigger, and puts back
-- sleep_night_minutes, compute_sleep_readiness and workout_hr_ref as they were live before v227 (v226).

BEGIN;

UPDATE public.realtime_health r SET hrv_rmssd = b.hrv_rmssd
  FROM public.realtime_health_hrv_v227_backup b WHERE b.id = r.id;

DROP TRIGGER IF EXISTS trg_guard_backfill_hrv ON public.realtime_health;
DROP FUNCTION IF EXISTS public.guard_backfill_hrv();

CREATE OR REPLACE FUNCTION public.sleep_night_minutes(p_user_id uuid, p_target_date date, p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS TABLE(n_m_ts timestamp with time zone, n_stage text, n_hr numeric, n_hrv numeric, n_pre_onset boolean, n_alcohol boolean)
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
  night_p05    int := NULL;   -- v151: night's own HR floor, drives adaptive thresholds
  adj          int := 0;      -- v151: scaled margin above the floor
  calm_low_run int := 0;      -- v169: longest sustained calm-low block (min); false-onset gate
  gap_fill_max int := 45;     -- v170: max missing-minute run counted as sleep (BLE dropout, not blackout)
  deep_cap     numeric := 0.20;  -- v176: physiological deep cap, pre-smoothing
  deep_time_k  numeric := 1.8;   -- v176: bpm-equivalent penalty per hour since onset
  min_rem_bout int := 5;         -- v176
  min_deep_bout int := 8;        -- v224: was 5 (v176); a 5-7 min deep island is noise at this resolution
  deep_res_max numeric := -1.0;  -- v224: deep needs smoothed HR at least this far under the local trend
  trend_win    int := 45;        -- v224: +/- minutes of the local HR trend
  deep_latency int := 15;        -- v224: no deep in the first N min after onset (N3 latency ~15-30 min)
  rem_latency  int := 60;        -- v224: no REM in the first N min after onset (healthy REM latency 70-120 min)
  deep_time_k2 numeric := 1.2;   -- v224: bpm of trend residual per hour since onset, front-loads deep
  deep_bridge  int := 2;         -- v224: light runs this short between two deep runs join them
  rem_bridge   int := 5;         -- v224: same for REM
  rem_cap      numeric := 0.17;  -- v224: REM share cap before smoothing (adult REM 20-25%)
  rem_time_k   numeric := 0.5;   -- v224: bpm of residual per hour, REM grows toward morning
  rem_density  numeric := 0.30;  -- v176: REM fraction over +/-5 min that sustains a REM bout
  deep_density numeric := 0.50;  -- v176: deep fraction over +/-3 min that sustains a deep bout
  eff_ceiling  int := 97;        -- v176
  prepend_hole_max int := 10;    -- v190: longest data hole the pre-onset prepend may cross
  personal_rhr numeric := NULL;  -- v193: his median sleeping RHR over the prior 60 complete nights
  plaus_margin int := 12;        -- v193: how far above it a short island may sit and still be sleep
  alc_floor_min int := 30;      -- v207: drinking nights judge waking against the floor of the surrounding +/- this many minutes
  alc_prepend_max int := 45;    -- v207: drinking nights may prepend this many calm minutes before onset as time in bed
  nap_end_before timestamptz := (p_target_date::text || ' 01:00:00')::timestamp AT TIME ZONE p_user_tz;  -- v225
  nap_awake_min int := 60;       -- v225: observed awake minutes after a short island that make it an evening nap
BEGIN
  -- v207: a night is a drinking night when he flagged it OR the detector fires. The flag used to be
  -- read only by the alarm, so a flagged night was staged with sober rules.
  is_alcohol := drinking_flagged_night(p_user_id, p_target_date)
                OR COALESCE(detect_overnight_alcohol(p_user_id, p_target_date, p_user_tz), false);

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.resting_hr) INTO personal_rhr
  FROM health_metrics hm
  WHERE hm.user_id = p_user_id
    AND hm.metric_date <  p_target_date
    AND hm.metric_date >= p_target_date - 60
    AND hm.sleep_complete IS TRUE
    AND NOT COALESCE(hm.excluded, false)
    AND hm.resting_hr BETWEEN 35 AND 90
  HAVING count(*) >= 7;
  IF is_alcohol THEN
    sleep_thresh := 75;
    wake_thresh  := 89;
    deep_ceiling := 62;
    rhr_floor    := 40;
    plaus_margin := plaus_margin + 10;
    resp_thresh  := 99;
  END IF;

  -- v151: ADAPTIVE FLOOR. The absolute sleep_thresh goes blind whenever the sleeping HR
  -- floor is elevated for ANY reason (alcohol the flag missed, heat, stress, illness).
  -- Track the night's OWN 5th-percentile HR + a fixed margin instead. Sober nights are
  -- byte-identical; only elevated nights lift.
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

  -- v169: FALSE-ONSET GATE. Real sleep contains a SUSTAINED block that is both LOW and
  -- STABLE. Under 15 min of that means there is no real sleep in the window -> emit nothing
  -- rather than manufacture one from the awake evening.
  -- v226: drinking nights too. The gate is relative to the night's own floor, so raised HR does not
  -- trip it: all five drinking nights 09-12..10-25 hold a calm block of 22-52 min.
  IF true THEN
    WITH mb AS (
      SELECT date_trunc('minute', recorded_at) AS m,
             AVG(heart_rate)::numeric AS hr,
             COALESCE(stddev_samp(heart_rate), 0)::numeric AS sd
      FROM realtime_health
      WHERE user_id = p_user_id
        AND recorded_at >= win_start AND recorded_at < win_end
        AND heart_rate IS NOT NULL AND heart_rate > 30
      GROUP BY date_trunc('minute', recorded_at)
    ),
    sm AS (
      SELECT m, AVG(hr) OVER (ORDER BY m ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS hrs, sd
      FROM mb
    ),
    fl AS (
      SELECT m, CASE WHEN hrs < night_p05 + 6 AND sd < 4 THEN 1 ELSE 0 END AS islow
      FROM sm
    ),
    lg AS (
      SELECT m, islow, LAG(islow, 1, islow) OVER (ORDER BY m) AS prev FROM fl
    ),
    gp AS (
      SELECT m, islow, SUM(CASE WHEN islow != prev THEN 1 ELSE 0 END) OVER (ORDER BY m) AS gid FROM lg
    )
    SELECT COALESCE(MAX(cnt), 0) INTO calm_low_run
    FROM (SELECT gid, COUNT(*) AS cnt FROM gp WHERE islow = 1 GROUP BY gid) z;

    IF calm_low_run < 15 THEN
      RETURN;   -- no sustained sleep block -> no window
    END IF;
  END IF;

  RETURN QUERY
  WITH minute_buckets AS (
    SELECT
      date_trunc('minute', recorded_at) AS m_ts,
      AVG(heart_rate)::numeric AS hr_avg,
      stddev_samp(heart_rate)::numeric AS hr_sd,
      AVG(hrv_rmssd)::numeric AS hrv_avg,
      AVG(respiratory_rate) FILTER (WHERE respiratory_rate > 0 AND respiratory_rate < 24)::numeric AS resp_avg
    FROM realtime_health
    WHERE user_id = p_user_id
      AND recorded_at >= win_start
      AND recorded_at <  win_end
      AND heart_rate IS NOT NULL
      AND heart_rate > 30
    GROUP BY date_trunc('minute', recorded_at)
  ),
  -- v224: per-minute RMSSD from the strap's beat-to-beat intervals (hrv_rmssd is a slow rolling value)
  rr_minutes AS (
    SELECT y.m_ts, sqrt(avg(y.d * y.d))::numeric AS rmssd
    FROM (
      SELECT date_trunc('minute', x.recorded_at) AS m_ts,
             x.rr - lag(x.rr) OVER (PARTITION BY date_trunc('minute', x.recorded_at) ORDER BY x.recorded_at, x.k) AS d
      FROM (SELECT r.recorded_at, u.rr::numeric AS rr, u.k
              FROM realtime_health r, unnest(r.rr_intervals) WITH ORDINALITY u(rr, k)
             WHERE r.user_id = p_user_id AND r.recorded_at >= win_start AND r.recorded_at < win_end
               AND r.rr_intervals IS NOT NULL) x
      WHERE x.rr BETWEEN 300 AND 2000) y
    WHERE abs(y.d) < 250
    GROUP BY y.m_ts
    HAVING count(*) >= 20
  ),
  imu_minutes AS (
    -- v185.1: real motion evidence, scale-invariant. The accelerometer LSB/g
    -- is disputed between RE sources (8192 vs 4096), so absolute movement_score
    -- can't be trusted until a real night calibrates it. Instead: a sleeping
    -- night's median |accel| IS 1 g in whatever units the strap speaks, so
    -- movement = |mag / night_median - 1| needs no scale at all.
    -- A minute only counts as covered when >= 20 of its seconds reported.
    WITH sec AS (
      SELECT recorded_at,
             sqrt((accel_x::float8)^2 + (accel_y::float8)^2 + (accel_z::float8)^2) AS mag
      FROM whoop_imu
      WHERE user_id = p_user_id
        AND recorded_at >= win_start
        AND recorded_at <  win_end
    ), ref AS (
      SELECT NULLIF(percentile_cont(0.5) WITHIN GROUP (ORDER BY mag), 0) AS g1 FROM sec
    )
    SELECT
      date_trunc('minute', s.recorded_at) AS m_ts,
      AVG(abs(s.mag / r.g1 - 1))::numeric AS imu_move_avg,
      MAX(abs(s.mag / r.g1 - 1))::numeric AS imu_move_max,
      COUNT(*)                            AS imu_n
    FROM sec s CROSS JOIN ref r
    WHERE r.g1 IS NOT NULL
    GROUP BY date_trunc('minute', s.recorded_at)
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
  -- v193: an island only becomes the night if it looks like HIS sleep. 10-08 picked a 2 h couch
  -- block at HR 70-77 (his sleeping RHR is ~53) because the strap went silent at 00:00 and cut
  -- the real night to 88 min. Spans of 4 h+ always qualify, so elevated drinking nights survive.
  longest_island AS (
    SELECT island_id
    FROM sleep_islands
    GROUP BY island_id
    HAVING personal_rhr IS NULL
        OR MAX(m_ts) - MIN(m_ts) >= interval '4 hours'
        -- v225: a short island that ends before 01:00 and is followed by an hour of him observed awake is the
        -- evening, not the night. 10-25: a calm couch block 19:00-22:12 (HR 65-72, drinking flag on) became the
        -- night after the app died at 01:34; he slept 01:35-11:00 and the alarm closed the night at 01:02.
        OR (percentile_cont(0.10) WITHIN GROUP (ORDER BY hr_smooth) <= personal_rhr + plaus_margin
            AND NOT (MAX(m_ts) < nap_end_before
                     AND (SELECT count(*) FROM bridged b
                           WHERE b.is_sleep = 0 AND b.m_ts > MAX(sleep_islands.m_ts)) >= nap_awake_min))
    ORDER BY COUNT(*) DESC
    LIMIT 1
  ),
  island_minutes AS (
    SELECT s.m_ts, s.hr_avg, s.hr_sd, s.hrv_avg, s.hr_smooth, sm.resp_smooth
    FROM sleep_islands s
    JOIN longest_island li ON s.island_id = li.island_id
    JOIN smoothed sm ON sm.m_ts = s.m_ts
  ),
  island_fwd AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      AVG(CASE WHEN resp_smooth < resp_thresh THEN 1.0 ELSE 0.0 END)
        FILTER (WHERE resp_smooth IS NOT NULL)
        OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 19 FOLLOWING) AS fwd_low_frac
    FROM island_minutes
  ),
  onset_anchor AS (
    SELECT COALESCE(
      MIN(m_ts) FILTER (WHERE fwd_low_frac >= 0.6 AND hr_smooth < sleep_thresh),
      MIN(m_ts)
    ) AS real_onset
    FROM island_fwd
  ),
  sleep_minutes AS (
    SELECT im.m_ts, im.hr_avg, im.hr_sd, im.hrv_avg, im.hr_smooth
    FROM island_minutes im, onset_anchor oa
    WHERE im.m_ts >= oa.real_onset
  ),
  night_floor AS (
    SELECT percentile_cont(0.10) WITHIN GROUP (ORDER BY hr_smooth) AS floor_hr
    FROM sleep_minutes
  ),
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
  onset0 AS (
    SELECT MIN(m_ts) AS ms FROM core_minutes
  ),
  pre_cand AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth, is_presleep,
      AVG(is_presleep::numeric) OVER (ORDER BY m_ts ROWS BETWEEN 4 PRECEDING AND 4 FOLLOWING) AS ps_frac,
      LEAD(m_ts, 1, ms0) OVER (ORDER BY m_ts) AS next_ts
    FROM (
      SELECT sm.m_ts, sm.hr_avg, sm.hr_sd, sm.hrv_avg, sm.hr_smooth, o.ms AS ms0,
        CASE WHEN sm.hr_smooth < wake_thresh AND sm.resp_smooth IS NOT NULL
                  AND sm.resp_smooth < resp_sleep_thresh THEN 1 ELSE 0 END AS is_presleep
      FROM smoothed sm, onset0 o
      WHERE sm.m_ts <  o.ms
        -- v207: on a drinking night only the last alc_prepend_max minutes may join, earlier evening minutes are still the night out
        AND sm.m_ts >= o.ms - CASE WHEN is_alcohol THEN make_interval(mins => alc_prepend_max) ELSE interval '4 hours' END
    ) q
  ),
  -- v190: the prepend walks back minute by minute, so it must stop at a data hole. Rows are
  -- only the minutes that reported; a 16-row chain could span 70 minutes of nothing and pull
  -- an awake 23:44 in as bedtime (08-07).
  pre_break AS (
    SELECT MAX(m_ts) AS bk FROM pre_cand
    WHERE ps_frac < 0.5 OR next_ts - m_ts > make_interval(mins => prepend_hole_max)
  ),
  prepend_minutes AS (
    SELECT pc.m_ts, pc.hr_avg, pc.hr_sd, pc.hrv_avg, pc.hr_smooth
    FROM pre_cand pc, pre_break pb
    WHERE pc.is_presleep = 1
      AND (pb.bk IS NULL OR pc.m_ts > pb.bk)
  ),
  final_minutes AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth FROM core_minutes
    UNION ALL
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth FROM prepend_minutes
  ),
  fm_enriched AS (
    -- v185: 'moving' is accelerometer-based when the minute has IMU coverage,
    -- HR-jitter otherwise -- so nights before the IMU stream existed (and any
    -- BLE gap) stage exactly as v184 did. Thresholds are first-guess until a
    -- night of real IMU data lands; recalibrate from the histogram then.
    SELECT fm.m_ts, fm.hr_avg, fm.hr_sd, fm.hrv_avg, fm.hr_smooth,
           sm.resp_smooth, nf.floor_hr,
           CASE WHEN COALESCE(im.imu_n, 0) >= 20
                THEN (im.imu_move_avg >= 0.05 OR im.imu_move_max >= 0.30)
                ELSE fm.hr_sd >= 3
           END AS moving,
           COALESCE(im.imu_n >= 20 AND im.imu_move_avg >= 0.15, false) AS moving_hard,
           -- v207: alcohol holds sleeping HR up early in the night and lets it fall as it clears. Against the whole
           -- night's floor the early minutes read as floor+14 = awake (2026-10-11: 61 of 70 awake minutes). On a drinking night
           -- the floor is the lowest smoothed HR within +/- alc_floor_min minutes, never below the night's floor.
           -- Sober nights keep the night's floor exactly.
           CASE WHEN is_alcohol
                THEN GREATEST(nf.floor_hr, MIN(fm.hr_smooth) OVER (ORDER BY fm.m_ts
                       RANGE BETWEEN make_interval(mins => alc_floor_min) PRECEDING AND make_interval(mins => alc_floor_min) FOLLOWING))
                ELSE nf.floor_hr END AS wake_floor,
           -- v224: deep and REM are judged against the night's own local HR trend, not one ceiling for the whole
           -- night. Sleeping HR drifts down for ~4 h, so a fixed ceiling put deep mid-night and none in cycle 1.
           fm.hr_smooth - AVG(fm.hr_smooth) FILTER (WHERE fm.hr_smooth < wake_thresh) OVER (ORDER BY fm.m_ts
             RANGE BETWEEN make_interval(mins => trend_win) PRECEDING AND make_interval(mins => trend_win) FOLLOWING) AS hr_res,
           rr.rmssd / NULLIF(AVG(rr.rmssd) OVER (ORDER BY fm.m_ts
             RANGE BETWEEN make_interval(mins => trend_win) PRECEDING AND make_interval(mins => trend_win) FOLLOWING), 0) AS rmssd_rel
    FROM final_minutes fm
    LEFT JOIN smoothed sm ON sm.m_ts = fm.m_ts
    LEFT JOIN imu_minutes im ON im.m_ts = fm.m_ts
    LEFT JOIN rr_minutes rr ON rr.m_ts = fm.m_ts
    CROSS JOIN night_floor nf
  ),
  -- v184: hi_frac is taken on the RAW minute, not the 5-min smoothed value. Smoothing
  -- twice (hr_smooth, then a 5-min majority of it) turned a 2-minute roll-over into
  -- 5-7 minutes of 'awake'. v185: mov_ct now counts real accelerometer minutes
  -- when the IMU stream covers them, HR jitter only as fallback.
  awake_flagged AS (
    SELECT fe.*,
      AVG(CASE WHEN hr_avg >= COALESCE(wake_floor, 999) + 9 THEN 1.0 ELSE 0.0 END)
        OVER (ORDER BY m_ts ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS hi_frac,
      SUM(CASE WHEN moving THEN 1 ELSE 0 END)
        OVER (ORDER BY m_ts ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS mov_ct
    FROM fm_enriched fe
  ),
  staged1 AS (
    SELECT aw.*,
      CASE
        -- v184: a soft-awake call (floor+9) needs movement in 2 of 5 minutes, or an
        -- unambiguous floor+14. Calm, elevated, steady-breathing minutes are sleep.
        WHEN hr_smooth > wake_thresh
          OR (hi_frac >= 0.5 AND (mov_ct >= 2 OR hr_smooth >= COALESCE(wake_floor, 999) + 14))
          -- v185: a sustained movement burst with any HR lift is awake, even
          -- when the 5-min smoothed HR never clears wake_thresh (short wakings)
          OR (moving_hard AND hr_avg >= COALESCE(wake_floor, 999) + 6) THEN 'awake'
        WHEN hr_smooth < deep_ceiling + 6 AND COALESCE(hr_res, 0) <= deep_res_max AND hr_sd < 3
             AND NOT moving
             AND COALESCE(rmssd_rel, 1) >= 0.9
             AND COALESCE(resp_smooth, 0) < 20 THEN 'deepcand'
        WHEN hr_sd > rem_sd_min AND COALESCE(hr_res, 0) >= -0.5 THEN 'rem'
        -- v224: REM also when HR sits above its local trend with beat-to-beat variability under it (sympathetic REM)
        WHEN COALESCE(hr_res, 0) >= 1.5 AND COALESCE(rmssd_rel, 1) < 0.95 AND NOT moving THEN 'rem'
        ELSE 'light'
      END AS s1
    FROM awake_flagged aw
  ),
  asleep_ct AS (
    SELECT count(*) FILTER (WHERE s1 <> 'awake') AS asleep_n,
           MIN(m_ts) AS onset_ts
    FROM staged1
  ),
  -- v176: rank deepcand minutes by HR PLUS a penalty for how late in the night they fall.
  -- Ranking on raw HR alone put slow-wave sleep in the wrong half of the night, because
  -- sleeping HR keeps drifting down until morning. deep_time_k is expressed in bpm per hour
  -- since onset, so it competes on the same scale as the HR it corrects.
  onset_v224 AS (
    SELECT COALESCE((SELECT real_onset FROM onset_anchor), (SELECT onset_ts FROM asleep_ct)) AS on1
  ),
  ranked AS (
    SELECT s.*,
      CASE WHEN s1 = 'deepcand' AND s.m_ts >= (SELECT on1 FROM onset_v224) + make_interval(mins => deep_latency)
        THEN row_number() OVER (PARTITION BY (s1 = 'deepcand' AND s.m_ts >= (SELECT on1 FROM onset_v224) + make_interval(mins => deep_latency))
                                ORDER BY (COALESCE(s.hr_res, 0) + deep_time_k2
                                          * (EXTRACT(epoch FROM (s.m_ts - (SELECT onset_ts FROM asleep_ct))) / 3600.0)) ASC,
                                         hr_sd ASC)
      END AS deep_rank,
      -- v224: REM is capped like deep and ranked by how far HR sits above its trend, later in the night first
      CASE WHEN s1 = 'rem' AND s.m_ts >= (SELECT on1 FROM onset_v224) + make_interval(mins => rem_latency)
        THEN row_number() OVER (PARTITION BY (s1 = 'rem' AND s.m_ts >= (SELECT on1 FROM onset_v224) + make_interval(mins => rem_latency))
                                ORDER BY (COALESCE(s.hr_res, 0) + rem_time_k
                                          * (EXTRACT(epoch FROM (s.m_ts - (SELECT onset_ts FROM asleep_ct))) / 3600.0)) DESC,
                                         hr_sd DESC)
      END AS rem_rank
    FROM staged1 s
  ),
  classified AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN s1 = 'awake' THEN 'awake'
        WHEN s1 = 'rem' AND rem_rank <= floor(rem_cap * (SELECT asleep_n FROM asleep_ct)) THEN 'rem'
        WHEN s1 = 'rem'   THEN 'light'
        WHEN s1 = 'light' THEN 'light'
        WHEN s1 = 'deepcand'
             AND deep_rank <= floor(deep_cap * (SELECT asleep_n FROM asleep_ct)) THEN 'deep'
        ELSE 'light'
      END AS stage
    FROM ranked
  ),
  -- v176: HYSTERESIS. The per-minute classifier has no memory, so a REM threshold crossing
  -- lasting one minute became a REM "bout". Re-decide each minute from the local density of
  -- its neighbours instead: a minute is REM if >= rem_density of the +/-5 min around it is
  -- REM, deep if > deep_density of the +/-3 min around it is deep. Deep wins ties. 'awake' is
  -- never rewritten -- brief awakenings are real and the efficiency denominator needs them.
  sm_frac AS (
    SELECT c.*,
      AVG(CASE WHEN stage = 'deep' THEN 1.0 ELSE 0.0 END) FILTER (WHERE stage <> 'awake')
        OVER (ORDER BY m_ts ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING) AS f_deep,
      AVG(CASE WHEN stage = 'rem'  THEN 1.0 ELSE 0.0 END) FILTER (WHERE stage <> 'awake')
        OVER (ORDER BY m_ts ROWS BETWEEN 5 PRECEDING AND 5 FOLLOWING) AS f_rem
    FROM classified c
  ),
  smoothed_stage AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN stage = 'awake' THEN 'awake'
        WHEN COALESCE(f_deep, 0) >  deep_density THEN 'deep'
        WHEN COALESCE(f_rem,  0) >= rem_density  THEN 'rem'
        ELSE 'light'
      END AS stage
    FROM sm_frac
  ),
  -- v176: MINIMUM BOUT. Anything that survives smoothing but still lasts under 5 minutes is
  -- not a sleep cycle, it is noise. Demote to light.
  -- v224: a light run of 1-2 min inside one deep bout (or 1-3 min inside REM) is the same bout, not two
  sm_bouts AS (
    SELECT q.*, SUM(CASE WHEN q.stage IS DISTINCT FROM q.prev0 THEN 1 ELSE 0 END) OVER (ORDER BY q.m_ts) AS sb
    FROM (SELECT ss.*, LAG(ss.stage) OVER (ORDER BY ss.m_ts) AS prev0 FROM smoothed_stage ss) q
  ),
  sm_ctx AS (
    SELECT sb, stage, len, LAG(stage) OVER (ORDER BY sb) AS pst, LEAD(stage) OVER (ORDER BY sb) AS nst
    FROM (SELECT sb, MIN(stage) AS stage, COUNT(*) AS len FROM sm_bouts GROUP BY sb) r
  ),
  stage_bridged AS (
    SELECT b.m_ts, b.hr_avg, b.hr_sd, b.hrv_avg, b.hr_smooth,
      CASE WHEN c.stage = 'light' AND c.pst = c.nst
                AND ((c.pst = 'deep' AND c.len <= deep_bridge) OR (c.pst = 'rem' AND c.len <= rem_bridge))
           THEN c.pst ELSE b.stage END AS stage
    FROM sm_bouts b JOIN sm_ctx c USING (sb)
  ),
  bout_tagged AS (
    SELECT z.*, SUM(CASE WHEN stage IS DISTINCT FROM prev THEN 1 ELSE 0 END)
      OVER (ORDER BY m_ts) AS bout_id
    FROM (SELECT s.*, LAG(stage) OVER (ORDER BY m_ts) AS prev FROM stage_bridged s) z
  ),
  bout_len AS (
    SELECT b.*, COUNT(*) OVER (PARTITION BY bout_id) AS blen FROM bout_tagged b
  ),
  final_stage AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN stage = 'rem'  AND blen < min_rem_bout  THEN 'light'
        WHEN stage = 'deep' AND blen < min_deep_bout THEN 'light'
        ELSE stage
      END AS stage
    FROM bout_len
  )
  SELECT fs.m_ts, fs.stage, fs.hr_avg, fs.hrv_avg, COALESCE(fs.m_ts < oa.real_onset, false), is_alcohol
  FROM final_stage fs CROSS JOIN onset_anchor oa
  ORDER BY fs.m_ts;
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_sleep_readiness(p_user_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(sri integer, hr_now numeric, hr_floor numeric, hr_gap numeric, rmssd_now numeric, resp_now numeric, ready boolean, eta_min integer, status text, message text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_floor numeric;
  v_hr numeric; v_rmssd numeric; v_resp numeric;
  v_day date := (p_at AT TIME ZONE 'Europe/Berlin')::date;
  v_woke timestamptz; v_last_h numeric; v_awake_h numeric;
  v_strain3 numeric; v_base_h numeric; v_ill numeric;
  p_awake numeric; p_load numeric; p_debt numeric; p_ill numeric; v_pressure numeric;
  v_wired boolean;
  v_sri int; v_eta int;
  why text[] := '{}';
BEGIN
  SELECT median INTO v_floor FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  IF v_floor IS NULL THEN
    SELECT median INTO v_floor FROM personal_baselines
     WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=90 AND n_obs>=3;
  END IF;
  v_floor := COALESCE(v_floor, 52);

  SELECT avg(heart_rate),
         avg(hrv_rmssd) FILTER (WHERE hrv_rmssd > 0),
         avg(respiratory_rate) FILTER (WHERE respiratory_rate > 0 AND respiratory_rate < 24)
    INTO v_hr, v_rmssd, v_resp
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate > 30
    AND recorded_at >= p_at - interval '10 minutes' AND recorded_at <= p_at;

  -- last real night before p_at: when he woke and how long he slept
  SELECT h.sleep_end, h.sleep_hours INTO v_woke, v_last_h
    FROM health_metrics h
   WHERE h.user_id=p_user_id AND h.sleep_end IS NOT NULL AND h.sleep_end <= p_at
     AND h.sleep_end > p_at - interval '30 hours' AND COALESCE(h.sleep_hours, 0) >= 2
   ORDER BY h.sleep_end DESC LIMIT 1;

  IF v_woke IS NULL AND v_hr IS NULL THEN
    sri:=NULL; hr_now:=NULL; hr_floor:=v_floor; hr_gap:=NULL; rmssd_now:=NULL; resp_now:=NULL;
    ready:=NULL; eta_min:=NULL; status:='⚪ no data'; message:='No recent strap data or last night to read.';
    RETURN NEXT; RETURN;
  END IF;

  v_awake_h := EXTRACT(epoch FROM p_at - v_woke) / 3600.0;

  SELECT avg(strain_score) INTO v_strain3 FROM health_metrics
   WHERE user_id=p_user_id AND metric_date BETWEEN v_day - 2 AND v_day AND strain_score IS NOT NULL;

  BEGIN
    SELECT t.base_h, t.d_illness INTO v_base_h, v_ill FROM public.target_sleep_duration(p_user_id, v_day) t;
  EXCEPTION WHEN OTHERS THEN v_base_h := NULL; v_ill := NULL;
  END;
  v_base_h := COALESCE(v_base_h, 8.0);

  -- sleep pressure, 0..1: 10 h awake is nothing, 16 h is full; load, debt and illness add to it
  p_awake := CASE WHEN v_awake_h IS NULL THEN 0.5 ELSE LEAST(GREATEST((v_awake_h - 10) / 6.0, 0), 1) END;
  p_load  := 0.3 * LEAST(GREATEST((COALESCE(v_strain3, 12) - 12) / 8.0, 0), 1);
  p_debt  := 0.3 * LEAST(GREATEST((v_base_h - COALESCE(v_last_h, v_base_h)) / 2.0, 0), 1);
  p_ill   := CASE WHEN COALESCE(v_ill, 0) > 0 THEN 0.15 ELSE 0 END;
  v_pressure := LEAST(p_awake + p_load + p_debt + p_ill, 1);

  IF v_awake_h IS NOT NULL THEN why := why || format('up %s h', round(v_awake_h, 1)); END IF;
  IF p_load >= 0.1 THEN why := why || format('3-day strain %s', round(v_strain3, 1)); END IF;
  IF p_debt >= 0.1 THEN why := why || format('short last night (%s h)', round(v_last_h, 1)); END IF;
  IF p_ill > 0 THEN why := why || 'illness signs'::text; END IF;

  -- HR only vetoes far above the usual pre-bed level: just trained, not just sitting at a desk
  v_wired := v_hr IS NOT NULL AND v_hr > v_floor + 48;

  v_sri := ROUND(100 * v_pressure * CASE WHEN v_wired THEN 0.6 ELSE 1 END);
  IF v_sri >= 70 THEN v_eta := 0;
  ELSIF v_wired THEN v_eta := 30;
  ELSE v_eta := LEAST(CEIL((0.7 - v_pressure) * 360), 240); END IF;

  sri:=v_sri; hr_now:=ROUND(v_hr,1); hr_floor:=v_floor; hr_gap:=ROUND(v_hr - v_floor,1);
  rmssd_now:=ROUND(v_rmssd,1); resp_now:=ROUND(v_resp,1); eta_min:=v_eta;
  ready := v_sri >= 70;

  IF v_sri >= 70 THEN
    status := '🟢 ready';
    message := format('Sleep pressure is high (%s). Lie down now: your heart comes down within about 15 min of lying down.',
                      array_to_string(why, ', '));
  ELSIF v_wired THEN
    status := '🔴 wired';
    message := format('Heart at %s, well above your usual evening. Give it ~30 min after training before bed.', ROUND(v_hr));
  ELSIF v_sri >= 40 THEN
    status := '🟡 getting there';
    message := format('Sleep pressure building (%s). About %s min until a good window.', array_to_string(why, ', '), v_eta);
  ELSE
    status := '🔵 early';
    message := format('Not much sleep pressure yet (%s). About %s min until a good window.', array_to_string(why, ', '), v_eta);
  END IF;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.workout_hr_ref(p_user_id uuid, OUT rest_hr numeric, OUT max_hr numeric, OUT thr_hr numeric)
 RETURNS record
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- Same resting HR and max HR the live zones use (workout_live), so a zone means one thing everywhere.
  SELECT r.v, m.v, r.v + 0.30 * (m.v - r.v)
    FROM (SELECT coalesce((SELECT median FROM personal_baselines
                            WHERE user_id = p_user_id AND metric = 'resting_hr' AND window_days = 30 AND n_obs >= 3), 50)::numeric v) r,
         (SELECT (220 - coalesce((SELECT age FROM user_body_profile WHERE user_id = p_user_id), 30))::numeric v) m;
$function$;

REVOKE EXECUTE ON FUNCTION public.workout_hr_ref(uuid) FROM authenticated;

COMMIT;
