-- v225 rollback - restores sleep_night_minutes and smart_wake_evaluate as they were live before v225 (v224).

BEGIN;

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
  -- STABLE. Under 15 min of that on a sober night means there is no real sleep in the
  -- window -> emit nothing rather than manufacture one from the awake evening.
  IF NOT is_alcohol THEN
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
        OR percentile_cont(0.10) WITHIN GROUP (ORDER BY hr_smooth) <= personal_rhr + plaus_margin
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

CREATE OR REPLACE FUNCTION public.smart_wake_evaluate(p_user_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(session_id uuid, should_fire boolean, reason text, stage text, wake_score integer, deep_prob numeric, slept_h_so_far numeric, target_h numeric, earliest_wake_at timestamp with time zone, target_wake_at timestamp with time zone, backstop_at timestamp with time zone, recovery_pct numeric, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s record; v_onset timestamptz; v_target numeric; floor_h numeric;
  v_earliest timestamptz; v_target_wake timestamptz; v_backstop timestamptz;
  sw_wake boolean; sw_score int; sw_dp numeric; sw_reason text;
  v_stage text; v_slept numeric;
  total_deep_min int; recent_hrv numeric; base_hrv numeric;
  hrv_rebound boolean; recovery_complete boolean; v_recpct numeric;
  v_should boolean := false; v_reason text; v_last_sample timestamptz;
  tz text := 'Europe/Berlin';
  v_need int; v_asleep int; v_aw6 int; v_n6 int; v_aw30 int; v_n30 int; v_deep4 int; v_aw4 int;
  v_alcohol boolean; v_last_min timestamptz; v_last_awake int; s5 record; s15 record;
  v_awake_now boolean; v_stopped boolean; v_light_ok boolean; v_blind_backstop timestamptz;
  v_last_any timestamptz; v_night_end timestamptz; v_night date;
  v_last_rt timestamptz; v_floor numeric; v_sleep_start timestamptz; v_cut boolean := false; v_was_awake boolean;
  v_lead int; v_raw_floor numeric; v_blank_awake boolean := false;
  v_aw60 int; v_n60 int; v_c6 int := 0; v_ch6 int := 0; v_c30 int := 0; v_ch30 int := 0; v_c60 int := 0; v_ch60 int := 0;
BEGIN
  SELECT * INTO s FROM smart_wake_sessions
   WHERE user_id=p_user_id AND smart_wake_sessions.status IN ('armed','asleep','ready')
   ORDER BY armed_at DESC LIMIT 1;

  IF s.id IS NULL THEN
    session_id:=NULL; should_fire:=false; reason:='no_armed_session'; status:='none';
    RETURN NEXT; RETURN;
  END IF;

  v_target := COALESCE(s.target_h, 8.0);
  v_onset  := s.sleep_onset_at;

  -- v175: floor is 7h when no clock deadline was set (never wake him short on a free morning).
  -- With an explicit deadline the old 6h floor stands so a real flight/train alarm still lands.
  floor_h := CASE WHEN s.latest_wake_at IS NULL
                  THEN GREATEST(7.0, 0.7 * v_target)
                  ELSE GREATEST(6.0, 0.7 * v_target) END;

  -- ---- Onset detection / transition ----
  IF v_onset IS NULL THEN
    v_onset := detect_live_sleep_onset(p_user_id, s.armed_at, p_now);
    IF v_onset IS NOT NULL THEN
      v_earliest    := v_onset + make_interval(mins => round(floor_h*60)::int);
      v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int);
      -- v175: default backstop follows the sleep need instead of a flat 9.5h, so there is always a
      -- real ~1h light-sleep hunting window after target instead of the 26 min a 9.06h target left.
      v_backstop    := COALESCE(s.latest_wake_at,
                         GREATEST(v_onset + interval '8 hours',
                                  v_onset + make_interval(mins => round((v_target + 1.0)*60)::int)));
      UPDATE smart_wake_sessions
         SET status='asleep', sleep_onset_at=v_onset,
             earliest_wake_at=v_earliest, target_wake_at=v_target_wake,
             backstop_at=v_backstop, updated_at=now()
       WHERE id=s.id;
    ELSE
      IF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at THEN
        session_id:=s.id; should_fire:=true; reason:='deadline_no_onset';
        stage:='unknown'; wake_score:=100; deep_prob:=NULL; slept_h_so_far:=NULL;
        target_h:=v_target; earliest_wake_at:=NULL; target_wake_at:=NULL;
        backstop_at:=s.latest_wake_at; recovery_pct:=NULL; status:=s.status;
        RETURN NEXT; RETURN;
      ELSIF p_now >= s.armed_at + interval '20 hours' THEN
        session_id:=s.id; should_fire:=false; reason:='expire_no_onset'; status:='armed';
        target_h:=v_target; RETURN NEXT; RETURN;
      ELSE
        session_id:=s.id; should_fire:=false; reason:='awaiting_onset'; status:='armed';
        target_h:=v_target; RETURN NEXT; RETURN;
      END IF;
    END IF;
  ELSE
    v_earliest    := s.earliest_wake_at;
    v_target_wake := s.target_wake_at;
    v_backstop    := s.backstop_at;
    IF v_earliest IS NULL THEN v_earliest := v_onset + make_interval(mins => round(floor_h*60)::int); END IF;
    IF v_target_wake IS NULL THEN v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int); END IF;
    IF v_backstop IS NULL THEN
      v_backstop := COALESCE(s.latest_wake_at,
                      GREATEST(v_onset + interval '8 hours',
                               v_onset + make_interval(mins => round((v_target + 1.0)*60)::int)));
    END IF;
  END IF;

  -- v213: the clock counts minutes ASLEEP from the same stager as the morning summary (drinking-aware
  -- since v207), not wall time since onset. The need is learned from asleep hours, so the wall clock woke
  -- him ~50 min short and he slept on (7 of 21 fires in 60 days). Awake is checked at every step,
  -- including at the window end, and the app's stop / "I'm awake" log ends the session.
  v_slept := round(EXTRACT(epoch FROM (p_now - v_onset))/3600.0, 2);
  IF p_now < v_onset + interval '5 hours' THEN
    session_id:=s.id; should_fire:=false; reason:='safety_floor'; stage:='unknown';
    slept_h_so_far:=v_slept; target_h:=v_target; earliest_wake_at:=v_earliest;
    target_wake_at:=v_target_wake; backstop_at:=v_backstop; status:=COALESCE(s.status,'asleep');
    RETURN NEXT; RETURN;
  END IF;

  -- the night a minute belongs to runs 19:00 to 12:00 (Berlin), as in sleep_night_minutes
  v_night := ((p_now AT TIME ZONE tz) + interval '5 hours')::date;
  v_night_end := (v_night::text || ' 12:00:00')::timestamp AT TIME ZONE tz;

  -- v_last_any counts minutes before the stager's own onset too: data flowing, him not asleep yet, is not a dead strap
  SELECT count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage <> 'awake'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '6 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '6 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '30 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '30 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'deep'  AND m.n_m_ts > p_now - interval '4 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '4 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '60 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '60 minutes'),
         percentile_cont(0.10) WITHIN GROUP (ORDER BY m.n_hr) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage <> 'awake'),
         min(m.n_m_ts) FILTER (WHERE NOT m.n_pre_onset),
         bool_or(m.n_alcohol), max(m.n_m_ts) FILTER (WHERE NOT m.n_pre_onset), max(m.n_m_ts)
    INTO v_asleep, v_aw6, v_n6, v_aw30, v_n30, v_deep4, v_aw4, v_aw60, v_n60, v_floor, v_sleep_start, v_alcohol, v_last_min, v_last_any
    FROM sleep_night_minutes(p_user_id, v_night) m
   WHERE m.n_m_ts <= p_now;
  v_asleep := COALESCE(v_asleep, 0);

  -- the stage of the last minutes the strap did send, for when it went quiet
  SELECT count(*) FILTER (WHERE m.n_stage = 'awake') INTO v_last_awake
    FROM sleep_night_minutes(p_user_id, v_night) m
   WHERE NOT m.n_pre_onset AND m.n_m_ts <= v_last_min AND m.n_m_ts > v_last_min - interval '6 minutes';


  -- v215: liveness comes from the strap's raw samples, not from the stager. The stager drops every minute after a
  -- wake it sees (15+ min of high heart rate once 4 h asleep), so its output going quiet means he is awake, not that
  -- the strap is off. 2026-10-13: he woke at 06:22 for ~15 min, the stager cut the tail, v213 read a dead strap after
  -- 5 h asleep and closed the night with no ring; he slept on to 09:45.
  SELECT max(r.recorded_at) INTO v_last_rt FROM realtime_health r
   WHERE r.user_id = p_user_id AND r.recorded_at > GREATEST(v_onset, p_now - interval '14 hours')
     AND r.recorded_at <= p_now AND r.heart_rate > 30;
  v_cut := v_last_rt >= p_now - interval '15 minutes' AND v_last_min IS NOT NULL
           AND v_last_min < p_now - interval '3 minutes';
  IF v_cut THEN
    -- the minutes the stager cut, judged the way it judges them: awake at the night's floor + 9 bpm
    SELECT count(*) FILTER (WHERE x.m > p_now - interval '6 minutes'),
           count(*) FILTER (WHERE x.m > p_now - interval '6 minutes' AND x.hr >= v_floor + 9),
           count(*) FILTER (WHERE x.m > p_now - interval '30 minutes'),
           count(*) FILTER (WHERE x.m > p_now - interval '30 minutes' AND x.hr >= v_floor + 9),
           count(*), count(*) FILTER (WHERE x.hr >= v_floor + 9)
      INTO v_c6, v_ch6, v_c30, v_ch30, v_c60, v_ch60
      FROM (SELECT date_trunc('minute', r.recorded_at) AS m, avg(r.heart_rate) AS hr FROM realtime_health r
             WHERE r.user_id = p_user_id AND r.recorded_at >= v_last_min + interval '1 minute'
               AND r.recorded_at > p_now - interval '60 minutes' AND r.recorded_at <= p_now AND r.heart_rate > 30
             GROUP BY 1) x;
  END IF;
  -- awake when the strap went quiet: the stager's last minutes say so, or raw data ran on 10+ min past its cut
  v_was_awake := COALESCE(v_last_awake, 0) >= 4
                 OR (v_last_rt IS NOT NULL AND v_last_min IS NOT NULL AND v_last_rt > v_last_min + interval '10 minutes');

  v_need := round(v_target * 60)::int;
  -- v218: the light-sleep window opens at the full need (was 30 min before it: rang 30 min short on 17 of 18 nights)
  SELECT ns.window_lead_min INTO v_lead FROM sleep_need_settings ns WHERE ns.user_id = p_user_id;
  v_lead := COALESCE(v_lead, 0);
  v_slept := round(v_asleep / 60.0, 2);
  v_target_wake := p_now + make_interval(mins => GREATEST(v_need - v_asleep, 0));
  v_earliest    := p_now + make_interval(mins => GREATEST(v_need - v_lead - v_asleep, 0));
  -- v215: never past need + 1 h or 10 h after he fell asleep (he is wrecked after 10 h), whichever comes first.
  -- Counted from the stager's onset when it is later, so a session onset logged too early cannot ring him at 05:00.
  v_blind_backstop := COALESCE(s.latest_wake_at,
                        LEAST(GREATEST(v_onset, COALESCE(v_sleep_start, v_onset)) + make_interval(mins => v_need + 60),
                              GREATEST(v_onset, COALESCE(v_sleep_start, v_onset)) + interval '10 hours',
                              GREATEST(v_night_end, v_onset + make_interval(mins => v_need))));
  v_backstop    := LEAST(v_blind_backstop, p_now + make_interval(mins => GREATEST(v_need + 45 - v_asleep, 0)));

  SELECT * INTO s5  FROM live_sleep_stage(p_user_id, p_now, 5)  z;
  SELECT * INTO s15 FROM live_sleep_stage(p_user_id, p_now, 15) z;
  v_awake_now := (v_n6 >= 4 AND v_aw6 >= v_n6 - 1)
              OR (COALESCE(s5.p_awake, 0) >= 0.35 AND COALESCE(s15.p_awake, 0) >= 0.30)
              OR (v_cut AND v_c6 >= 3 AND v_ch6 >= v_c6 - 1);

  v_stopped := EXISTS (SELECT 1 FROM bridge_logs b
                        WHERE b.user_id = p_user_id
                          AND b.category IN ('manual_wake_up','evt_alarm_stopped','smart_alarm_stopped')
                          AND b.created_at > v_onset + interval '3 hours' AND b.created_at <= p_now);

  -- light/REM must hold: the live check (now and 3 min ago) and no deep or awake minute in the last 4
  SELECT w.wake, w.wake_score, w.deep_prob, w.reason INTO sw_wake, sw_score, sw_dp, sw_reason
    FROM should_wake_now(p_user_id, p_now - interval '1 minute', p_now + interval '1 day', p_now) w;
  v_light_ok := sw_wake IS TRUE AND COALESCE(v_deep4, 0) = 0 AND COALESCE(v_aw4, 0) <= 1;

  v_stage := CASE WHEN v_awake_now THEN 'awake'
                  WHEN sw_dp IS NULL THEN 'unknown'
                  WHEN sw_dp >= 0.40 OR COALESCE(v_deep4,0) > 0 THEN 'deep'
                  ELSE 'light_rem' END;
  v_recpct := round(100 * LEAST(1.0, v_asleep::numeric / NULLIF(v_need, 0)));

  -- v219: the stager can go blank mid-night: its false-onset gate needs a 15 min calm block under the night's
  -- 5th-percentile HR + 6, and that bar drops as deeper minutes arrive (2026-10-16 05:30-06:02, run 18 -> 10 min).
  -- Blank, it read as 'not asleep yet' ahead of the latest check, so a blank stretch at the latest time rang nothing.
  -- Past the latest with the stager blank, judge awake from raw minutes the way the stager does (v184): floor = 10th
  -- percentile of calm minutes (sd < 3) since onset; a minute is up at floor + 9 with movement (sd >= 3) or at floor + 14.
  -- 3 of the last 6 such minutes holds the ring (that night: 0-10% of asleep minutes, 64% of awake minutes).
  IF v_last_min IS NULL AND p_now >= v_blind_backstop THEN
    SELECT percentile_cont(0.10) WITHIN GROUP (ORDER BY x.hr) INTO v_raw_floor
      FROM (SELECT date_trunc('minute', r.recorded_at) AS m, avg(r.heart_rate) AS hr,
                   COALESCE(stddev_samp(r.heart_rate), 0) AS sd FROM realtime_health r
             WHERE r.user_id = p_user_id AND r.recorded_at >= v_onset AND r.recorded_at <= p_now AND r.heart_rate > 30
             GROUP BY 1) x
     WHERE x.sd < 3;
    SELECT count(*), count(*) FILTER (WHERE (x.hr >= v_raw_floor + 9 AND x.sd >= 3) OR x.hr >= v_raw_floor + 14)
      INTO v_c6, v_ch6
      FROM (SELECT date_trunc('minute', r.recorded_at) AS m, avg(r.heart_rate) AS hr,
                   COALESCE(stddev_samp(r.heart_rate), 0) AS sd FROM realtime_health r
             WHERE r.user_id = p_user_id AND r.recorded_at > p_now - interval '6 minutes' AND r.recorded_at <= p_now
               AND r.heart_rate > 30
             GROUP BY 1) x;
    v_blank_awake := v_ch6 >= 3;
  END IF;

  -- ---- Decision ----
  IF v_stopped THEN
    v_should := false; v_reason := 'stopped_by_you';
  ELSIF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at THEN
    v_should := true;  v_reason := 'deadline';                       -- a deadline is never cancelled
  ELSIF p_now >= v_night_end THEN
    v_should := false; v_reason := 'night_over';                     -- the night's minutes stop at 12:00; he is up
  ELSIF v_last_rt IS NULL OR v_last_rt < p_now - interval '15 minutes' THEN
    v_stage := 'unknown';                                            -- no strap samples in 15 min: there is no stage to report
    IF v_was_awake AND v_asleep >= v_need - 90 THEN
      v_should := false; v_reason := 'woke_on_own';                  -- up near his need when the strap went quiet
    ELSIF p_now >= v_blind_backstop THEN
      v_should := true;  v_reason := 'backstop_blind';               -- a dead strap or phone mid-sleep still rings
    ELSE
      v_should := false; v_reason := 'no_live_data_hold';
    END IF;
  ELSIF v_last_rt < p_now - interval '5 minutes' THEN
    v_should := false; v_reason := 'no_live_data_hold';              -- samples thinning out: decide on fresh data only
  ELSIF v_last_min IS NULL AND p_now >= v_blind_backstop AND NOT COALESCE(v_awake_now, false) AND NOT v_blank_awake THEN
    v_should := true;  v_reason := 'latest_reached';                 -- v219: stager blank mid-night, the latest still rings
  ELSIF v_last_min IS NULL THEN
    v_should := false; v_reason := 'not_asleep_yet';                 -- data flows, the stager has not seen him fall asleep
  ELSIF v_awake_now AND v_n30 + v_c30 >= 24 AND v_aw30 + v_ch30 >= 24 AND v_asleep >= v_need - 30 THEN
    v_should := false; v_reason := 'woke_on_own';                    -- need nearly met and up for 24 of the last 30 min
  ELSIF v_awake_now AND v_n60 + v_c60 >= 50 AND v_aw60 + v_ch60 >= 50 THEN
    v_should := false; v_reason := 'woke_on_own';                    -- up for the last hour: he has started his day
  ELSIF v_awake_now THEN
    v_should := false; v_reason := 'awake_hold';                     -- awake for now: never ring into it, keep the night open
  ELSIF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at - interval '30 minutes' AND v_light_ok THEN
    v_should := true;  v_reason := 'deadline_light';                 -- inside the last 30 min before a deadline, take light sleep
  ELSIF p_now >= v_blind_backstop THEN
    v_should := true;  v_reason := 'latest_reached';                 -- need + 1 h or 10 h after onset: the latest, counted or not
  ELSIF v_asleep < v_need - v_lead THEN
    v_should := false; v_reason := 'need_not_met';
  ELSIF v_light_ok THEN
    v_should := true;  v_reason := 'need_met_light';
  ELSIF v_asleep >= v_need + 45 THEN
    v_should := true;  v_reason := 'backstop_reached';
  ELSIF v_asleep >= v_need + 30 AND v_stage <> 'deep' THEN
    v_should := true;  v_reason := 'window_end';
  ELSE
    v_should := false; v_reason := CASE WHEN v_stage = 'deep' THEN 'deep_hold' ELSE 'light_hold' END;
  END IF;

  session_id := s.id; should_fire := v_should; reason := v_reason;
  stage := v_stage; wake_score := sw_score; deep_prob := sw_dp;
  slept_h_so_far := v_slept; target_h := v_target;
  earliest_wake_at := v_earliest; target_wake_at := v_target_wake;
  backstop_at := v_backstop; recovery_pct := v_recpct;
  status := CASE WHEN v_should THEN 'ready' ELSE COALESCE(s.status,'asleep') END;
  RETURN NEXT;
END;$function$;

COMMIT;
