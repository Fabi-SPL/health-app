-- ============================================================================
-- v172 — sleep window edge clamp
--
-- Problem v171 created. The hole rule (max_gap >= 60) treats a dropout at the
-- very EDGE of the detected window the same as a dropout in the middle of it.
-- Those are not the same thing. A hole in the middle means we lost hours we
-- believed we were watching. A hole at the leading edge means the window simply
-- opened before recording did — the night itself was fine.
--
-- 2026-08-12 is the case that proved it: detected window 22:27 -> 09:58, but
-- realtime_health has nothing from 22:27 to 00:00 (93 min, upload path stalled
-- while BLE stayed live). 567 of 691 minutes observed, dense clean sleep HR from
-- 00:00 onward. v171 withheld sleep_hours, sleep_score, recovery_score, hrv_avg
-- and resting_hr over a hole that sat entirely outside the recorded night.
--
-- Fix: before measuring, peel edge-adjacent dropouts off the window. Note the
-- shape of the real failure — there is one lone sample at 22:27 and then 92 dead
-- minutes, so the hole is not strictly *before* the first observation, it sits
-- one minute inside the rim. So the rule is positional, not observational: if the
-- largest hole starts within 30 min of the window's start (or ends within 30 min
-- of its end), re-anchor past it. You cannot claim sleep at a minute you have no
-- data for, so trim it rather than punish the whole night for it. Trimmed window
-- for last night is 00:00 -> 09:58: coverage 86%, max gap 17 min, complete.
--
-- Guard that keeps this from becoming the opposite bug: clamping can only help a
-- night that still has a night left after the trim. If the trim happened and the
-- surviving window is under 5h, withhold. Without this, 2026-08-11 (91 observed
-- minutes inside a 10h window) would clamp down to a 91-minute window at ~100%
-- coverage and publish 1.5h of sleep as a complete night, which is exactly the
-- number that made this whole audit necessary.
--
-- Clamping only engages when an edge gap is >= 20 min, so ordinary nights are
-- measured exactly as they were under v171.
-- ============================================================================

-- Signature changes (three new OUT columns), so replace is not enough.
DROP FUNCTION IF EXISTS public.sleep_window_quality(uuid, date, timestamptz, timestamptz, integer, text);

CREATE FUNCTION public.sleep_window_quality(
  p_user_id     uuid,
  p_target_date date,
  p_sleep_start timestamptz,
  p_sleep_end   timestamptz,
  p_asleep_min  integer,
  p_user_tz     text DEFAULT 'Europe/Berlin'
)
RETURNS TABLE(
  o_coverage_pct       integer,
  o_max_gap_min        integer,
  o_blackout_after_min integer,
  o_complete           boolean,
  o_reason             text,
  o_start_used         timestamptz,
  o_end_used           timestamptz,
  o_trimmed_min        integer
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  edge_trim_min constant int := 20;   -- a hole this big is a recording failure, not sleep
  edge_zone_min constant int := 30;   -- how close to the rim a hole must sit to count as edge-adjacent
  min_span_min  constant int := 300;  -- a trimmed window shorter than 5h is not a night
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
  first_after timestamptz;
  blackout    int;
BEGIN
  IF p_sleep_start IS NULL OR p_sleep_end IS NULL THEN RETURN; END IF;
  s := p_sleep_start;
  e := p_sleep_end;
  s_orig := s;
  e_orig := e;

  -- Peel edge-adjacent dropouts off the window. A hole that sits against either
  -- rim tells you the window opened before recording began (or stayed open after
  -- it stopped) — it does not tell you a recorded night has hours missing from
  -- its middle. Two passes handle a bad head and a bad tail on the same night.
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

  -- silence immediately following the window, out to the detector's own horizon
  SELECT MIN(date_trunc('minute', recorded_at)) INTO first_after
  FROM realtime_health
  WHERE user_id = p_user_id AND recorded_at >= e AND recorded_at < win_end
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  blackout := CASE WHEN first_after IS NULL
                   THEN GREATEST(0, (EXTRACT(epoch FROM (win_end - e))/60)::int)
                   ELSE GREATEST(0, (EXTRACT(epoch FROM (first_after - e))/60)::int) END;

  o_coverage_pct       := cov;
  o_max_gap_min        := max_gap;
  o_blackout_after_min := blackout;
  o_start_used         := s;
  o_end_used           := e;
  o_trimmed_min        := trimmed;

  o_reason := NULL;
  IF trimmed > 0 AND span_min < min_span_min THEN
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

-- ----------------------------------------------------------------------------
-- recompute_health_metrics: store the window we actually measured, not the one
-- the stager guessed. Identical to v171 apart from sleep_start / sleep_end.
-- ----------------------------------------------------------------------------
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

  -- v171: was the night actually observed? A window the stager found is not the
  -- same thing as a night we watched.
  -- v172: the gate clamps edge dropouts out of the window first, and hands back
  -- the window it actually measured.
  SELECT * INTO q FROM sleep_window_quality(
    p_user_id, target_date, win.o_sleep_start, win.o_sleep_end, win.o_asleep_min);
  ok := COALESCE(q.o_complete, true);

  IF ok THEN
    s_score := compute_sleep_score(
      win.o_total_min, win.o_asleep_min, win.o_deep_min, win.o_rem_min, win.o_efficiency_pct);
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
    sleep_complete, sleep_incomplete_reason
  )
  VALUES (
    p_user_id, target_date, 'pg_recompute',
    COALESCE(q.o_start_used, win.o_sleep_start),
    COALESCE(q.o_end_used,   win.o_sleep_end),
    CASE WHEN ok THEN ROUND(win.o_asleep_min / 60.0, 1) END,
    win.o_deep_min, win.o_rem_min, win.o_light_min, win.o_awake_min,
    CASE WHEN ok THEN win.o_efficiency_pct END, s_score, r_score,
    CASE WHEN ok THEN win.o_hrv_avg END,
    CASE WHEN ok THEN win.o_resting_hr END,
    CASE WHEN NOT ok        THEN 'incomplete'
         WHEN is_low_conf   THEN 'low_confidence'
         WHEN r_score >= 67 THEN 'green'
         WHEN r_score >= 34 THEN 'yellow'
         ELSE 'red' END,
    r_score,
    CASE WHEN is_alcohol THEN 1.0 ELSE NULL END,
    st_clean,
    q.o_coverage_pct, q.o_max_gap_min, win.o_asleep_min,
    ok, q.o_reason
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
    sleep_incomplete_reason = EXCLUDED.sleep_incomplete_reason;

  SELECT * INTO result_row FROM health_metrics
  WHERE user_id = p_user_id AND metric_date = target_date;
  RETURN result_row;
END;
$function$;
