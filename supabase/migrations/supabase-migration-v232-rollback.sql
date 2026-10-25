-- v232 rollback - restores sleep_window_quality as it ran before v232 (dumped live 2026-10-25 20:30 Berlin).

BEGIN;

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
  -- v190
  win_start   timestamptz := ((p_target_date - 1)::text || ' 19:00:00')::timestamp AT TIME ZONE p_user_tz;
  horizon     timestamptz := LEAST((p_target_date::text || ' 12:00:00')::timestamp AT TIME ZONE p_user_tz, date_trunc('minute', now()));
  no_window   boolean := false;
  head_unseen boolean := false;
  anchor      timestamptz;
  first_seen  timestamptz;
  prev_seen   timestamptz;
  lead_len    int := 0;
  gaps_txt    text;
  gaps_more   int := 0;
BEGIN
  -- v190: a night without a window still gets a verdict, so the row can say why there is
  -- no sleep on it instead of reading as a night he did not sleep. Never past now().
  win_end := horizon;
  IF p_sleep_start IS NULL OR p_sleep_end IS NULL THEN
    no_window := true;
    s := win_start;
    e := horizon;
    IF e <= s THEN RETURN; END IF;
  ELSE
    s := p_sleep_start;
    e := p_sleep_end;
  END IF;
  s_orig := s;
  e_orig := e;

  -- Peel edge-adjacent dropouts off the window. A hole that sits against either
  -- rim tells you the window opened before recording began (or stayed open after
  -- it stopped) — it does not tell you a recorded night has hours missing from
  -- its middle.
  FOR pass IN 1..(CASE WHEN no_window THEN 0 ELSE 3 END) LOOP
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

  -- v190: the mirror image of truncation. Recording that only begins as the window opens,
  -- after an hour or more of silence, with the first minutes already at the sleeping floor,
  -- means onset happened inside the hole: a short measured night there is cut off, not short.
  IF NOT no_window AND COALESCE(p_asleep_min, 0) < min_span_min THEN
    -- the silence can sit before the window as detected, or before the start the edge trim moved to
    FOREACH anchor IN ARRAY ARRAY[s_orig, s] LOOP
      SELECT MIN(date_trunc('minute', recorded_at)) INTO first_seen FROM realtime_health
      WHERE user_id = p_user_id AND recorded_at >= anchor - make_interval(mins => tail_grace_min) AND recorded_at < e
        AND heart_rate IS NOT NULL AND heart_rate > 30;
      SELECT MAX(date_trunc('minute', recorded_at)) INTO prev_seen FROM realtime_health
      WHERE user_id = p_user_id AND recorded_at >= win_start AND recorded_at < first_seen
        AND heart_rate IS NOT NULL AND heart_rate > 30;
      lead_len := COALESCE((EXTRACT(epoch FROM (first_seen - COALESCE(prev_seen + interval '1 minute', win_start))) / 60)::int, 0);
      EXIT WHEN lead_len >= 60;
    END LOOP;
    IF first_seen IS NOT NULL AND lead_len >= 60 THEN
      WITH mb AS (
        SELECT date_trunc('minute', recorded_at) m, avg(heart_rate) hr FROM realtime_health
        WHERE user_id = p_user_id AND recorded_at >= first_seen AND recorded_at < e
          AND heart_rate IS NOT NULL AND heart_rate > 30
        GROUP BY 1
      )
      SELECT (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hr) FROM (SELECT hr FROM mb ORDER BY m LIMIT 10) f)
             < percentile_cont(0.10) WITHIN GROUP (ORDER BY hr) + 10
        INTO head_unseen FROM mb;
      head_unseen := COALESCE(head_unseen, false);
    END IF;
  END IF;

  -- v190: name the holes. "only 59% observed" told him nothing he could act on.
  WITH have AS (
    SELECT DISTINCT date_trunc('minute', recorded_at) m FROM realtime_health
    WHERE user_id = p_user_id AND recorded_at >= win_start AND recorded_at < horizon
      AND heart_rate IS NOT NULL AND heart_rate > 30
  ), allm AS (
    SELECT generate_series(win_start, horizon - interval '1 minute', interval '1 minute') m
  ), miss AS (
    SELECT a.m FROM allm a LEFT JOIN have h ON h.m = a.m WHERE h.m IS NULL
  ), grp AS (
    SELECT m, (EXTRACT(epoch FROM m)/60)::bigint - row_number() OVER (ORDER BY m) g FROM miss
  ), runs AS (
    SELECT MIN(m) rs, MAX(m) + interval '1 minute' re, count(*)::int len FROM grp GROUP BY g
  ), hit AS (
    SELECT rs, re, row_number() OVER (ORDER BY len DESC, rs) rk FROM runs
    WHERE len >= CASE WHEN no_window THEN 60 ELSE edge_trim_min END
      AND re >= s_orig AND rs <= e_orig
      -- with no window, only holes that reach into the core night (23:00-09:00) are news
      AND (NOT no_window OR (re > win_start + interval '4 hours' AND rs < win_start + interval '14 hours'))
  )
  SELECT string_agg(to_char(rs AT TIME ZONE p_user_tz, 'HH24:MI') || '-' || to_char(re AT TIME ZONE p_user_tz, 'HH24:MI'), ', ' ORDER BY rs)
           FILTER (WHERE rk <= 3),
         count(*) FILTER (WHERE rk > 3)
    INTO gaps_txt, gaps_more
  FROM hit;
  IF gaps_txt IS NOT NULL THEN
    gaps_txt := 'strap data missing ' || gaps_txt
                || CASE WHEN gaps_more > 0 THEN format(' and %s shorter gaps', gaps_more) ELSE '' END;
  END IF;

  o_coverage_pct       := cov;
  o_max_gap_min        := max_gap;
  o_blackout_after_min := blackout;
  o_start_used         := s;
  o_end_used           := e;
  o_trimmed_min        := trimmed;

  o_reason := NULL;
  IF no_window THEN
    o_start_used := NULL;
    o_end_used   := NULL;
    o_reason := CASE
      WHEN measured = 0 THEN
        format('no strap data recorded between 19:00 and %s', to_char(horizon AT TIME ZONE p_user_tz, 'HH24:MI'))
      WHEN COALESCE(p_asleep_min, 0) > 0 THEN
        format('only %s min of sleep found, too little to call a night', p_asleep_min)
        || COALESCE('; ' || gaps_txt, '')
      WHEN gaps_txt IS NOT NULL THEN
        format('too little data to find the night: %s (%s recorded between 19:00 and %s)', gaps_txt,
               CASE WHEN measured < 60 THEN measured || ' min' ELSE ROUND(measured / 60.0, 1) || 'h' END,
               to_char(horizon AT TIME ZONE p_user_tz, 'HH24:MI'))
      ELSE
        format('no sleep block found in %sh of recorded data', ROUND(measured / 60.0, 1))
    END;
  ELSIF truncated THEN
    o_reason := format(
      'recording stopped at %s and stayed dead for %sh%s — the night was cut off, not short. %sh was measured before that; the rest is unknown.',
      to_char(died_at AT TIME ZONE p_user_tz, 'HH24:MI'),
      blackout / 60, lpad((blackout % 60)::text, 2, '0'),
      ROUND(COALESCE(p_asleep_min, 0) / 60.0, 1));
  ELSIF head_unseen THEN
    o_reason := format(
      'strap data missing %s-%s, so sleep onset was not recorded. %sh was measured after that; the rest is unknown.',
      to_char(COALESCE(prev_seen + interval '1 minute', win_start) AT TIME ZONE p_user_tz, 'HH24:MI'),
      to_char(first_seen AT TIME ZONE p_user_tz, 'HH24:MI'),
      ROUND(COALESCE(p_asleep_min, 0) / 60.0, 1));
  ELSIF trimmed > 0 AND span_min < min_span_min THEN
    o_reason := format('only %sh of the night was actually recorded', ROUND(span_min / 60.0, 1))
                || COALESCE('; ' || gaps_txt, '');
  ELSIF cov < 70 THEN
    o_reason := format('only %s%% of the night was observed', cov) || COALESCE('; ' || gaps_txt, '');
  ELSIF max_gap >= 60 THEN
    o_reason := format('%s min of the night is missing in one block', max_gap) || COALESCE('; ' || gaps_txt, '');
  ELSIF blackout >= 60 AND COALESCE(p_asleep_min, 0) < 300 THEN
    o_reason := format('recording stopped for %s min right after only %sh of sleep',
                       blackout, ROUND(COALESCE(p_asleep_min, 0) / 60.0, 1)) || COALESCE('; ' || gaps_txt, '');
  END IF;
  o_complete := (o_reason IS NULL);
  RETURN NEXT;
END;
$function$;

-- Put the three re-scored August nights back as they were.
SET LOCAL lucid.server_write = 'on';
UPDATE health_metrics h SET
  (source, sleep_start, sleep_end, sleep_hours, deep_sleep_min, rem_sleep_min, light_sleep_min, awake_min, sleep_efficiency_pct, sleep_score, recovery_score, hrv_avg, resting_hr, readiness_level, readiness_score, alcohol_impact, skin_temp, sleep_coverage_pct, sleep_max_gap_min, sleep_measured_min, sleep_complete, sleep_incomplete_reason, sleep_consistency_pct, respiratory_rate, sdnn_avg, pnn50_avg, dfa_alpha1_avg, poincare_sd1, poincare_sd2, poincare_ratio, nocturnal_hr_dip, sleep_debt_hours, vo2max_estimate, cognitive_capacity_score, cognitive_label)
  = (b.source, b.sleep_start, b.sleep_end, b.sleep_hours, b.deep_sleep_min, b.rem_sleep_min, b.light_sleep_min, b.awake_min, b.sleep_efficiency_pct, b.sleep_score, b.recovery_score, b.hrv_avg, b.resting_hr, b.readiness_level, b.readiness_score, b.alcohol_impact, b.skin_temp, b.sleep_coverage_pct, b.sleep_max_gap_min, b.sleep_measured_min, b.sleep_complete, b.sleep_incomplete_reason, b.sleep_consistency_pct, b.respiratory_rate, b.sdnn_avg, b.pnn50_avg, b.dfa_alpha1_avg, b.poincare_sd1, b.poincare_sd2, b.poincare_ratio, b.nocturnal_hr_dip, b.sleep_debt_hours, b.vo2max_estimate, b.cognitive_capacity_score, b.cognitive_label)
  FROM health_metrics_v232_backup b
 WHERE h.user_id = b.user_id AND h.metric_date = b.metric_date;
DROP TABLE health_metrics_v232_backup;

COMMIT;
