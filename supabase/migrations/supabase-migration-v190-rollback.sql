-- v190 rollback: restores detect_sleep_window, sleep_window_quality and recompute_health_metrics as live before 2026-10-04

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
  night_p05    int := NULL;   -- v151: night's own HR floor, drives adaptive thresholds
  adj          int := 0;      -- v151: scaled margin above the floor
  calm_low_run int := 0;      -- v169: longest sustained calm-low block (min); false-onset gate
  gap_fill_max int := 45;     -- v170: max missing-minute run counted as sleep (BLE dropout, not blackout)
  deep_cap     numeric := 0.20;  -- v176: physiological deep cap, pre-smoothing
  deep_time_k  numeric := 1.8;   -- v176: bpm-equivalent penalty per hour since onset
  min_rem_bout int := 5;         -- v176
  min_deep_bout int := 5;        -- v176
  rem_density  numeric := 0.30;  -- v176: REM fraction over +/-5 min that sustains a REM bout
  deep_density numeric := 0.50;  -- v176: deep fraction over +/-3 min that sustains a deep bout
  eff_ceiling  int := 97;        -- v176
BEGIN
  SELECT detect_overnight_alcohol(p_user_id, p_target_date, p_user_tz) INTO is_alcohol;
  IF is_alcohol THEN
    sleep_thresh := 75;
    wake_thresh  := 89;
    deep_ceiling := 62;
    rhr_floor    := 40;
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
  longest_island AS (
    SELECT island_id
    FROM sleep_islands
    GROUP BY island_id
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
      AVG(is_presleep::numeric) OVER (ORDER BY m_ts ROWS BETWEEN 4 PRECEDING AND 4 FOLLOWING) AS ps_frac
    FROM (
      SELECT sm.m_ts, sm.hr_avg, sm.hr_sd, sm.hrv_avg, sm.hr_smooth,
        CASE WHEN sm.hr_smooth < wake_thresh AND sm.resp_smooth IS NOT NULL
                  AND sm.resp_smooth < resp_sleep_thresh THEN 1 ELSE 0 END AS is_presleep
      FROM smoothed sm, onset0 o
      WHERE NOT is_alcohol
        AND sm.m_ts <  o.ms
        AND sm.m_ts >= o.ms - interval '4 hours'
    ) q
  ),
  pre_break AS (
    SELECT MAX(m_ts) AS bk FROM pre_cand WHERE ps_frac < 0.5
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
           COALESCE(im.imu_n >= 20 AND im.imu_move_avg >= 0.15, false) AS moving_hard
    FROM final_minutes fm
    LEFT JOIN smoothed sm ON sm.m_ts = fm.m_ts
    LEFT JOIN imu_minutes im ON im.m_ts = fm.m_ts
    CROSS JOIN night_floor nf
  ),
  -- v184: hi_frac is taken on the RAW minute, not the 5-min smoothed value. Smoothing
  -- twice (hr_smooth, then a 5-min majority of it) turned a 2-minute roll-over into
  -- 5-7 minutes of 'awake'. v185: mov_ct now counts real accelerometer minutes
  -- when the IMU stream covers them, HR jitter only as fallback.
  awake_flagged AS (
    SELECT fe.*,
      AVG(CASE WHEN hr_avg >= COALESCE(floor_hr, 999) + 9 THEN 1.0 ELSE 0.0 END)
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
          OR (hi_frac >= 0.5 AND (mov_ct >= 2 OR hr_smooth >= COALESCE(floor_hr, 999) + 14))
          -- v185: a sustained movement burst with any HR lift is awake, even
          -- when the 5-min smoothed HR never clears wake_thresh (short wakings)
          OR (moving_hard AND hr_avg >= COALESCE(floor_hr, 999) + 6) THEN 'awake'
        WHEN hr_smooth < deep_ceiling AND hr_sd < 3
             AND NOT moving
             AND COALESCE(resp_smooth, 0) < 20 THEN 'deepcand'
        WHEN hr_sd > rem_sd_min THEN 'rem'
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
  ranked AS (
    SELECT s.*,
      CASE WHEN s1 = 'deepcand'
        THEN row_number() OVER (PARTITION BY (s1 = 'deepcand')
                                ORDER BY (hr_smooth + deep_time_k
                                          * (EXTRACT(epoch FROM (s.m_ts - (SELECT onset_ts FROM asleep_ct))) / 3600.0)) ASC,
                                         hr_sd ASC)
      END AS deep_rank
    FROM staged1 s
  ),
  classified AS (
    SELECT m_ts, hr_avg, hr_sd, hrv_avg, hr_smooth,
      CASE
        WHEN s1 = 'awake' THEN 'awake'
        WHEN s1 = 'rem'   THEN 'rem'
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
  bout_tagged AS (
    SELECT z.*, SUM(CASE WHEN stage IS DISTINCT FROM prev THEN 1 ELSE 0 END)
      OVER (ORDER BY m_ts) AS bout_id
    FROM (SELECT s.*, LAG(stage) OVER (ORDER BY m_ts) AS prev FROM smoothed_stage s) z
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
  ),
  -- v170: BLE-DROPOUT FILL. A missing minute is not an awake minute. Count a run of missing
  -- minutes as sleep only when it is short enough to be a radio dropout (<= gap_fill_max) AND
  -- is bracketed by asleep minutes on both sides. Filled minutes book as 'light'.
  cls_bounds AS (
    SELECT MIN(m_ts) AS ws, MAX(m_ts) AS we FROM final_stage
  ),
  all_min AS (
    SELECT generate_series(ws, we, interval '1 minute') AS m_ts FROM cls_bounds
  ),
  miss AS (
    SELECT a.m_ts FROM all_min a
    LEFT JOIN final_stage c ON c.m_ts = a.m_ts
    WHERE c.m_ts IS NULL
  ),
  miss_g AS (
    SELECT m_ts,
      (EXTRACT(epoch FROM m_ts)/60)::bigint - row_number() OVER (ORDER BY m_ts) AS grp
    FROM miss
  ),
  miss_runs AS (
    SELECT grp, COUNT(*)::int AS run_len, MIN(m_ts) AS gs, MAX(m_ts) AS ge
    FROM miss_g GROUP BY grp
  ),
  gap_fill AS (
    SELECT COALESCE(SUM(r.run_len), 0)::int AS fill_m
    FROM miss_runs r
    WHERE r.run_len <= gap_fill_max
      AND (SELECT c.stage FROM final_stage c WHERE c.m_ts = r.gs - interval '1 minute') <> 'awake'
      AND (SELECT c.stage FROM final_stage c WHERE c.m_ts = r.ge + interval '1 minute') <> 'awake'
  ),
  -- v176: SLEEP ONSET LATENCY. The prepend pass adds pre-onset drowsy minutes to the window
  -- and they were being staged 'light', i.e. counted as time ASLEEP. They are time in bed
  -- NOT asleep. Hold them in the efficiency denominator and out of its numerator. Capped at
  -- 90 min so a pathological prepend cannot swallow the night.
  latency AS (
    SELECT LEAST(90, (
      SELECT count(*) FROM final_stage f2, onset_anchor oa
      WHERE f2.m_ts < oa.real_onset AND f2.stage <> 'awake'
    ))::int AS lat_m
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
    FROM final_stage
  )
  SELECT
    t.w_start,
    t.w_end,
    EXTRACT(epoch FROM (t.w_end - t.w_start))::int / 60 AS total_min,
    (t.deep_m + t.rem_m + t.light_m + gf.fill_m) AS asleep_min,
    t.deep_m, t.rem_m, (t.light_m + gf.fill_m) AS light_m, t.awake_m,
    CASE WHEN (t.deep_m + t.rem_m + t.light_m + gf.fill_m + t.awake_m) > 0
         THEN LEAST(eff_ceiling,
                GREATEST(0, ROUND((GREATEST(0, t.deep_m + t.rem_m + t.light_m + gf.fill_m - lt.lat_m)::numeric
                     / (t.deep_m + t.rem_m + t.light_m + gf.fill_m + t.awake_m)) * 100)::int))
         ELSE 0 END AS eff_pct,
    ROUND(t.hrv_mean, 1) AS hrv_avg_out,
    ROUND(t.rhr_p5)::int AS rhr_out
  FROM totals t CROSS JOIN gap_fill gf CROSS JOIN latency lt
  WHERE t.w_start IS NOT NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sleep_window_quality(p_user_id uuid, p_target_date date, p_sleep_start timestamp with time zone, p_sleep_end timestamp with time zone, p_asleep_min integer, p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS TABLE(o_coverage_pct integer, o_max_gap_min integer, o_blackout_after_min integer, o_complete boolean, o_reason text, o_start_used timestamp with time zone, o_end_used timestamp with time zone, o_trimmed_min integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  edge_trim_min constant int := 20;   -- a hole this big is a recording failure, not sleep
  edge_zone_min constant int := 30;   -- how close to the rim a hole must sit to count as edge-adjacent
  min_span_min  constant int := 300;  -- a trimmed window shorter than 5h is not a night
  tail_grace_min constant int := 10;  -- silence starting this soon after the window ended it
  win_end     timestamptz := (p_target_date::text || ' 12:00:00')::timestamp AT TIME ZONE p_user_tz;
  s           timestamptz;
  e           timestamptz;
  s_orig      timestamptz;
  e_orig      timestamptz;
  run_start   timestamptz;
  run_end     timestamptz;
  run_len     int;
  trimmed     int := 0;
  pass        int;
  span_min    int;
  measured    int;
  cov         int;
  max_gap     int := 0;
  blackout    int := 0;
  died_at     timestamptz;
  truncated   boolean := false;
BEGIN
  IF p_sleep_start IS NULL OR p_sleep_end IS NULL THEN RETURN; END IF;
  s := p_sleep_start;
  e := p_sleep_end;
  s_orig := s;
  e_orig := e;

  -- Peel edge-adjacent dropouts off the window. A hole that sits against either
  -- rim tells you the window opened before recording began (or stayed open after
  -- it stopped) — it does not tell you a recorded night has hours missing from
  -- its middle.
  FOR pass IN 1..3 LOOP
    WITH have AS (
      SELECT DISTINCT date_trunc('minute', recorded_at) m FROM realtime_health
      WHERE user_id = p_user_id AND recorded_at >= s AND recorded_at < e
        AND heart_rate IS NOT NULL AND heart_rate > 30
    ), allm AS (
      SELECT generate_series(date_trunc('minute', s), e - interval '1 minute', interval '1 minute') m
    ), miss AS (
      SELECT a.m FROM allm a LEFT JOIN have h ON h.m = a.m WHERE h.m IS NULL
    ), grp AS (
      SELECT m, (EXTRACT(epoch FROM m)/60)::bigint - row_number() OVER (ORDER BY m) g FROM miss
    ), runs AS (
      SELECT MIN(m) rs, MAX(m) re, count(*)::int len FROM grp GROUP BY g
    )
    SELECT rs, re, len INTO run_start, run_end, run_len
    FROM runs ORDER BY len DESC, rs LIMIT 1;

    EXIT WHEN run_len IS NULL OR run_len < edge_trim_min;

    IF (EXTRACT(epoch FROM (run_start - s)) / 60)::int <= edge_zone_min THEN
      s := run_end + interval '1 minute';
    ELSIF (EXTRACT(epoch FROM (e - (run_end + interval '1 minute'))) / 60)::int <= edge_zone_min THEN
      e := run_start;
    ELSE
      EXIT;  -- the biggest hole is interior; that is a real gap and stays punished
    END IF;
  END LOOP;

  trimmed := GREATEST(0, (EXTRACT(epoch FROM ((s - s_orig) + (e_orig - e))) / 60)::int);
  IF e <= s THEN e := s + interval '1 minute'; END IF;
  span_min := GREATEST(1, (EXTRACT(epoch FROM (e - s)) / 60)::int);

  SELECT count(DISTINCT date_trunc('minute', recorded_at))::int INTO measured
  FROM realtime_health
  WHERE user_id = p_user_id AND recorded_at >= s AND recorded_at < e
    AND heart_rate IS NOT NULL AND heart_rate > 30;
  cov := LEAST(100, ROUND(100.0 * measured / span_min))::int;

  -- longest continuous run of missing minutes inside the (clamped) window
  WITH have AS (
    SELECT DISTINCT date_trunc('minute', recorded_at) m FROM realtime_health
    WHERE user_id = p_user_id AND recorded_at >= s AND recorded_at < e
      AND heart_rate IS NOT NULL AND heart_rate > 30
  ), allm AS (
    SELECT generate_series(date_trunc('minute', s), e - interval '1 minute', interval '1 minute') m
  ), miss AS (
    SELECT a.m FROM allm a LEFT JOIN have h ON h.m = a.m WHERE h.m IS NULL
  ), grp AS (
    SELECT m, (EXTRACT(epoch FROM m)/60)::bigint - row_number() OVER (ORDER BY m) g FROM miss
  )
  SELECT COALESCE(MAX(c), 0)::int INTO max_gap
  FROM (SELECT g, count(*) c FROM grp GROUP BY g) z;

  -- v182: the LONGEST silence between the window end and the detector's horizon,
  -- and when it began. The old version measured the distance to the first sample
  -- after the window, so a single stray minute of data past the rim reported a
  -- 0-minute blackout and hid a four-hour outage behind it.
  WITH have AS (
    SELECT DISTINCT date_trunc('minute', recorded_at) m FROM realtime_health
    WHERE user_id = p_user_id AND recorded_at >= e AND recorded_at < win_end
      AND heart_rate IS NOT NULL AND heart_rate > 30
  ), allm AS (
    SELECT generate_series(date_trunc('minute', e), win_end - interval '1 minute', interval '1 minute') m
  ), miss AS (
    SELECT a.m FROM allm a LEFT JOIN have h ON h.m = a.m WHERE h.m IS NULL
  ), grp AS (
    SELECT m, (EXTRACT(epoch FROM m)/60)::bigint - row_number() OVER (ORDER BY m) g FROM miss
  ), runs AS (
    SELECT MIN(m) rs, count(*)::int len FROM grp GROUP BY g
  )
  SELECT COALESCE(len, 0), rs INTO blackout, died_at
  FROM runs ORDER BY len DESC, rs LIMIT 1;

  blackout := COALESCE(blackout, 0);

  -- Truncation: recording stopped within minutes of the window end and stayed
  -- dead for an hour, AFTER an implausibly short night. All three conditions are
  -- needed. Without the asleep_min gate this also fires on a normal 7h night that
  -- ends when he gets up and walks away from the phone — verified against the last
  -- 30 nights, where dropping the gate produced 3 false positives (08-08, 08-14,
  -- 08-15) against 1 true one. A full night followed by silence is a man leaving
  -- the room; a 3h night followed by silence is a dead phone.
  truncated := died_at IS NOT NULL
               AND blackout >= 60
               AND (EXTRACT(epoch FROM (died_at - e)) / 60)::int <= tail_grace_min
               AND COALESCE(p_asleep_min, 0) < min_span_min;

  o_coverage_pct       := cov;
  o_max_gap_min        := max_gap;
  o_blackout_after_min := blackout;
  o_start_used         := s;
  o_end_used           := e;
  o_trimmed_min        := trimmed;

  o_reason := NULL;
  IF truncated THEN
    o_reason := format(
      'recording stopped at %s and stayed dead for %sh%s — the night was cut off, not short. %sh was measured before that; the rest is unknown.',
      to_char(died_at AT TIME ZONE p_user_tz, 'HH24:MI'),
      blackout / 60, lpad((blackout % 60)::text, 2, '0'),
      ROUND(COALESCE(p_asleep_min, 0) / 60.0, 1));
  ELSIF trimmed > 0 AND span_min < min_span_min THEN
    o_reason := format('only %sh of the night was actually recorded', ROUND(span_min / 60.0, 1));
  ELSIF cov < 70 THEN
    o_reason := format('only %s%% of the night was observed', cov);
  ELSIF max_gap >= 60 THEN
    o_reason := format('%s min of the night is missing in one block', max_gap);
  ELSIF blackout >= 60 AND COALESCE(p_asleep_min, 0) < 300 THEN
    o_reason := format('recording stopped for %s min right after only %sh of sleep',
                       blackout, ROUND(COALESCE(p_asleep_min, 0) / 60.0, 1));
  END IF;
  o_complete := (o_reason IS NULL);
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.recompute_health_metrics(p_user_id uuid, p_target_date date DEFAULT NULL::date)
 RETURNS health_metrics
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  target_date         date;
  win                 record;
  q                   record;
  s_score             numeric;
  r_score             numeric;
  consistency         numeric;
  result_row          health_metrics;
  has_open_alert      boolean;
  has_recent_backfill boolean;
  is_alcohol          boolean;
  st_clean            numeric;
  is_low_conf         boolean;
  ok                  boolean;
BEGIN
  target_date := COALESCE(p_target_date, (now() AT TIME ZONE 'Europe/Berlin')::date);

  SELECT detect_overnight_alcohol(p_user_id, target_date) INTO is_alcohol;
  st_clean := clean_skin_temp_day(p_user_id, target_date);

  SELECT * INTO win FROM detect_sleep_window(p_user_id, target_date);

  IF win.o_sleep_start IS NULL OR COALESCE(win.o_asleep_min, 0) < 60 THEN
    -- ===== NO-SCORE PATH (no usable sleep window) =====
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
      IF result_row.metric_date IS NULL THEN RETURN NULL; END IF;
      RETURN result_row;
    END IF;

    INSERT INTO health_metrics (user_id, metric_date, source, alcohol_impact, skin_temp)
    VALUES (p_user_id, target_date, 'pg_recompute', CASE WHEN is_alcohol THEN 1.0 ELSE NULL END, st_clean)
    ON CONFLICT (user_id, metric_date) DO UPDATE SET
      alcohol_impact = CASE WHEN is_alcohol THEN 1.0 ELSE health_metrics.alcohol_impact END,
      skin_temp      = COALESCE(EXCLUDED.skin_temp, health_metrics.skin_temp);

    SELECT * INTO result_row FROM health_metrics
    WHERE user_id = p_user_id AND metric_date = target_date;
    RETURN result_row;
  END IF;

  -- ===== SCORED PATH =====
  is_low_conf := COALESCE(win.o_asleep_min, 0) < 240;

  -- v171/v172: was the night actually observed? A window the stager found is not the same
  -- thing as a night we watched. The gate clamps edge dropouts out first.
  SELECT * INTO q FROM sleep_window_quality(
    p_user_id, target_date, win.o_sleep_start, win.o_sleep_end, win.o_asleep_min);
  ok := COALESCE(q.o_complete, true);

  IF ok THEN
    -- v176: NULL here means genuine cold start (<5 prior nights of bedtime), and
    -- compute_sleep_score renormalises rather than substituting a fake 50.
    consistency := sleep_consistency_score(p_user_id, target_date);
    s_score := compute_sleep_score(
      win.o_total_min, win.o_asleep_min, win.o_deep_min, win.o_rem_min,
      win.o_efficiency_pct, consistency);
    r_score := compute_recovery_score(
      p_user_id, win.o_hrv_avg, win.o_resting_hr, s_score, target_date);
  ELSE
    s_score := NULL; r_score := NULL;
  END IF;

  INSERT INTO health_metrics (
    user_id, metric_date, source,
    sleep_start, sleep_end, sleep_hours,
    deep_sleep_min, rem_sleep_min, light_sleep_min, awake_min,
    sleep_efficiency_pct, sleep_score, recovery_score,
    hrv_avg, resting_hr,
    readiness_level, readiness_score, alcohol_impact, skin_temp,
    sleep_coverage_pct, sleep_max_gap_min, sleep_measured_min,
    sleep_complete, sleep_incomplete_reason, sleep_consistency_pct
  )
  VALUES (
    p_user_id, target_date, 'pg_recompute',
    COALESCE(q.o_start_used, win.o_sleep_start),
    COALESCE(q.o_end_used,   win.o_sleep_end),
    CASE WHEN ok THEN ROUND(win.o_asleep_min / 60.0, 1) END,
    win.o_deep_min, win.o_rem_min, win.o_light_min, win.o_awake_min,
    CASE WHEN ok THEN win.o_efficiency_pct END, s_score, r_score,
    -- v188: HRV and RHR are measured, not inferred. A night that was cut off
    -- cannot give a sleep score or a recovery score, but the hours that WERE
    -- recorded are a real reading. Nulling them threw away the only vitals a
    -- short/interrupted night produces. >=90 min of sleep is the floor.
    CASE WHEN ok OR COALESCE(win.o_asleep_min, 0) >= 90 THEN win.o_hrv_avg END,
    CASE WHEN ok OR COALESCE(win.o_asleep_min, 0) >= 90 THEN win.o_resting_hr END,
    CASE WHEN NOT ok        THEN 'incomplete'
         WHEN is_low_conf   THEN 'low_confidence'
         WHEN r_score >= 67 THEN 'green'
         WHEN r_score >= 34 THEN 'yellow'
         ELSE 'red' END,
    r_score,
    CASE WHEN is_alcohol THEN 1.0 ELSE NULL END,
    st_clean,
    q.o_coverage_pct, q.o_max_gap_min, win.o_asleep_min,
    ok, q.o_reason,
    -- v183: the column existed and was NULL on every row for 90 days while this very
    -- function was already computing the value and throwing it away.
    CASE WHEN consistency IS NULL THEN NULL ELSE round(consistency) END
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
    alcohol_impact = CASE WHEN is_low_conf
                          THEN CASE WHEN is_alcohol THEN 1.0 ELSE health_metrics.alcohol_impact END
                          ELSE EXCLUDED.alcohol_impact END,
    skin_temp = COALESCE(EXCLUDED.skin_temp, health_metrics.skin_temp),
    sleep_coverage_pct = EXCLUDED.sleep_coverage_pct,
    sleep_max_gap_min = EXCLUDED.sleep_max_gap_min,
    sleep_measured_min = EXCLUDED.sleep_measured_min,
    sleep_complete = EXCLUDED.sleep_complete,
    sleep_incomplete_reason = EXCLUDED.sleep_incomplete_reason,
    sleep_consistency_pct = COALESCE(EXCLUDED.sleep_consistency_pct, health_metrics.sleep_consistency_pct);

  SELECT * INTO result_row FROM health_metrics
  WHERE user_id = p_user_id AND metric_date = target_date;
  RETURN result_row;
END;
$function$;

