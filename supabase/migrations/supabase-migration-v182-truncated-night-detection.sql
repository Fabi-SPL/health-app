-- v182 — a night that was cut short by a dead phone must never be reported as a short night
--
-- 2026-08-28: Fabi's phone died at 05:14. health_metrics said sleep_hours 3.3,
-- sleep_score 41, recovery 12, sleep_complete TRUE, sleep_coverage_pct 100.
-- Every one of those numbers is wrong, and the last two are why nothing caught it.
--
-- Two compounding flaws:
--
-- 1. Circularity. Coverage is measured INSIDE the detected sleep window, but the
--    window's own end is set by where the data stops. A truncated night is always
--    100% covered by construction. detect_sleep_window returned end 05:13 local;
--    the last sample was 05:14.
--
-- 2. The blackout guard measured the distance from the window end to the FIRST
--    sample after it. Data trickled one minute past the window before dying, so
--    first_after was 05:14 and blackout computed as 0 instead of 226. The guard
--    was looking at the leading gap when it needed the longest one.
--
-- Fix: measure the longest silence anywhere between the window end and the
-- detector's noon horizon, and separately test for truncation — recording that
-- stops within 10 minutes of the window end and stays dead for an hour did not
-- observe the end of the night, whatever the window says.
--
-- Downstream this already does the right thing: recompute_health_metrics writes
-- sleep_hours only when o_complete is true, so an incomplete night stores NULL
-- hours, NULL score, NULL recovery, plus sleep_measured_min and a plain-English
-- sleep_incomplete_reason. Readers get "the phone died" instead of "3.3 hours".

CREATE OR REPLACE FUNCTION public.sleep_window_quality(
  p_user_id uuid, p_target_date date,
  p_sleep_start timestamptz, p_sleep_end timestamptz,
  p_asleep_min integer, p_user_tz text DEFAULT 'Europe/Berlin'::text)
RETURNS TABLE(o_coverage_pct integer, o_max_gap_min integer, o_blackout_after_min integer,
              o_complete boolean, o_reason text, o_start_used timestamptz,
              o_end_used timestamptz, o_trimmed_min integer)
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
