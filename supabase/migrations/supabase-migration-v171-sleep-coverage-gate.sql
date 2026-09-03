-- v171 — the sleep-coverage gate. Stop publishing a night we did not observe.
--
-- 2026-08-11: the phone died at 01:43 CEST and data resumed at 11:53. A 610-minute
-- hole sat inside the detected sleep window, and the pipeline still published
-- sleep_hours=1.5 AND recovery_score=45 with excluded=false and no marker of any
-- kind. health_metrics had no coverage column at all, so the pipeline could only
-- publish a number or nothing — and it chose to publish. That is the same failure
-- shape as the fabricated 24.0 respiratory rate v167 had to null out: the system
-- inventing a measurement instead of saying "I did not see this."
--
-- v170 already fixed the OPPOSITE error (short BLE dropouts were deleting real
-- sleep, so runs <= 45 min bracketed by asleep minutes are now counted). This is
-- the other half: a blackout too large to reconstruct must invalidate the night's
-- published measurements rather than shrink them into a plausible-looking number.
--
-- Threshold calibration is empirical, not guessed. Over the 82 stored nights with
-- a detected window (2026-05-13 .. 2026-08-11):
--   complete nights   coverage 77..100%,  max interior hole 0..43 min
--   broken nights     coverage 15..67%,   max interior hole 106..610 min
-- The bands do not overlap. 70% coverage and a 60-minute hole both land in the
-- empty space between them. 12 of 82 nights (15%) flag.
--
-- What a flagged night publishes: nothing derived. sleep_hours, sleep_score,
-- recovery_score, readiness_score, sleep_efficiency_pct, hrv_avg and resting_hr
-- all go NULL. A resting HR taken from 90 observed minutes of a 10-hour night is
-- not that day's resting HR, and it feeds the illness CuSum baselines — so it is
-- an invented measurement too, not a partial one. The raw evidence is kept
-- (sleep_start/end, stage minutes, sleep_measured_min) plus the quality fields,
-- so the UI can say "night incomplete, 1.5h of 11h observed" instead of "you
-- slept 1.5 hours". Downstream consumers already filter on IS NOT NULL / > 0, so
-- flagged nights drop out of every baseline with no further changes.
--
-- Self-healing: this is computed on every recompute. If the strap later backfills
-- the missing minutes, coverage rises, the gate passes, and the night publishes
-- normally on the next run. Nothing is permanently blanked.

alter table public.health_metrics
  add column if not exists sleep_coverage_pct      int,
  add column if not exists sleep_max_gap_min       int,
  add column if not exists sleep_measured_min      int,
  add column if not exists sleep_complete          boolean,
  add column if not exists sleep_incomplete_reason text;

comment on column public.health_metrics.sleep_coverage_pct is
  'v171: % of minutes inside [sleep_start, sleep_end) that actually carry a heart-rate sample.';
comment on column public.health_metrics.sleep_complete is
  'v171: false => the derived sleep/recovery numbers were withheld, not measured. NULL => not yet evaluated.';

-- Quality of the observation, independent of what the sleep stager concluded.
-- Three failure modes, each a different way the night can be unobserved:
--   1. thin coverage across the whole window (BLE flapping all night)
--   2. one large hole inside the window (phone died mid-night, resumed later)
--   3. the window ends INTO a blackout on a short night — the wake time is a
--      data-loss artifact, not a wake event. Gated on asleep < 5h so that
--      "slept 8h, took the strap off at 07:15" never trips it.
create or replace function public.sleep_window_quality(
  p_user_id     uuid,
  p_target_date date,
  p_sleep_start timestamptz,
  p_sleep_end   timestamptz,
  p_asleep_min  int,
  p_user_tz     text default 'Europe/Berlin'
) returns table(
  o_coverage_pct       int,
  o_max_gap_min        int,
  o_blackout_after_min int,
  o_complete           boolean,
  o_reason             text
)
language plpgsql
stable
set search_path to 'public','extensions','pg_temp'
as $$
DECLARE
  win_end     timestamptz := (p_target_date::text || ' 12:00:00')::timestamp AT TIME ZONE p_user_tz;
  span_min    int;
  measured    int;
  cov         int;
  max_gap     int := 0;
  first_after timestamptz;
  blackout    int;
BEGIN
  IF p_sleep_start IS NULL OR p_sleep_end IS NULL THEN RETURN; END IF;
  span_min := GREATEST(1, (EXTRACT(epoch FROM (p_sleep_end - p_sleep_start))/60)::int);

  SELECT count(DISTINCT date_trunc('minute', recorded_at))::int INTO measured
  FROM realtime_health
  WHERE user_id=p_user_id AND recorded_at >= p_sleep_start AND recorded_at < p_sleep_end
    AND heart_rate IS NOT NULL AND heart_rate > 30;
  cov := LEAST(100, ROUND(100.0 * measured / span_min))::int;

  -- longest continuous run of missing minutes inside the window
  WITH have AS (
    SELECT DISTINCT date_trunc('minute', recorded_at) m FROM realtime_health
    WHERE user_id=p_user_id AND recorded_at >= p_sleep_start AND recorded_at < p_sleep_end
      AND heart_rate IS NOT NULL AND heart_rate > 30
  ), allm AS (
    SELECT generate_series(date_trunc('minute',p_sleep_start),
                           p_sleep_end - interval '1 minute', interval '1 minute') m
  ), miss AS (
    SELECT a.m FROM allm a LEFT JOIN have h ON h.m=a.m WHERE h.m IS NULL
  ), grp AS (
    SELECT m, (EXTRACT(epoch FROM m)/60)::bigint - row_number() OVER (ORDER BY m) g FROM miss
  )
  SELECT COALESCE(MAX(c),0)::int INTO max_gap
  FROM (SELECT g, count(*) c FROM grp GROUP BY g) z;

  -- silence immediately following the window, out to the detector's own horizon
  SELECT MIN(date_trunc('minute', recorded_at)) INTO first_after
  FROM realtime_health
  WHERE user_id=p_user_id AND recorded_at >= p_sleep_end AND recorded_at < win_end
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  blackout := CASE WHEN first_after IS NULL
                   THEN GREATEST(0,(EXTRACT(epoch FROM (win_end - p_sleep_end))/60)::int)
                   ELSE GREATEST(0,(EXTRACT(epoch FROM (first_after - p_sleep_end))/60)::int) END;

  o_coverage_pct := cov; o_max_gap_min := max_gap; o_blackout_after_min := blackout;
  o_reason := NULL;
  IF cov < 70 THEN
    o_reason := format('only %s%% of the night was observed', cov);
  ELSIF max_gap >= 60 THEN
    o_reason := format('%s min of the night is missing in one block', max_gap);
  ELSIF blackout >= 60 AND COALESCE(p_asleep_min,0) < 300 THEN
    o_reason := format('recording stopped for %s min right after only %sh of sleep',
                       blackout, ROUND(COALESCE(p_asleep_min,0)/60.0,1));
  END IF;
  o_complete := (o_reason IS NULL);
  RETURN NEXT;
END;
$$;

-- recompute_health_metrics: identical to v170 except for the gate. The no-score
-- path, the sync-in-flight defer, the alcohol-preservation rules and the skin_temp
-- COALESCE guards are all unchanged.
create or replace function public.recompute_health_metrics(p_user_id uuid, p_target_date date default null::date)
returns health_metrics
language plpgsql
set search_path to 'public','extensions','pg_temp'
as $function$
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
    win.o_sleep_start, win.o_sleep_end,
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

-- Backfill. Evaluates every stored night that has not been through the gate yet
-- and withholds the derived numbers on the ones that fail. Uses each row's OWN
-- stored sleep_start/sleep_end rather than re-running detect_sleep_window, so the
-- gate is the only thing that changes: no old night gets silently re-derived by a
-- newer detector. Idempotent — the sleep_complete IS NULL guard skips rows already
-- evaluated. Ran 2026-08-11: 128 nights evaluated, 13 withheld, 115 unchanged.
--
-- The 2026-03-22 floor is load-bearing, not a convenience window. realtime_health
-- only exists from that date — it is where the BLE era starts. Everything older is
-- whoop_backfill (452 rows, from 2024-06-25) and apple_health (152 rows), which are
-- Whoop's own published numbers with no per-minute samples to measure coverage
-- against. Run the gate over them and it reports 0% coverage for ~604 good nights
-- and blanks them all. Never lower this bound.
with q as (
  select h.metric_date md, x.*
  from health_metrics h
  cross join lateral sleep_window_quality(
    h.user_id, h.metric_date, h.sleep_start, h.sleep_end, (h.sleep_hours*60)::int) x
  where h.sleep_start is not null
    and h.sleep_complete is null
    and h.metric_date >= '2026-03-22'
)
update health_metrics h set
  sleep_coverage_pct      = q.o_coverage_pct,
  sleep_max_gap_min       = q.o_max_gap_min,
  sleep_measured_min      = (h.sleep_hours*60)::int,
  sleep_complete          = q.o_complete,
  sleep_incomplete_reason = q.o_reason,
  sleep_hours          = case when q.o_complete then h.sleep_hours end,
  sleep_score          = case when q.o_complete then h.sleep_score end,
  recovery_score       = case when q.o_complete then h.recovery_score end,
  readiness_score      = case when q.o_complete then h.readiness_score end,
  sleep_efficiency_pct = case when q.o_complete then h.sleep_efficiency_pct end,
  hrv_avg              = case when q.o_complete then h.hrv_avg end,
  resting_hr           = case when q.o_complete then h.resting_hr end,
  readiness_level      = case when q.o_complete then h.readiness_level else 'incomplete' end
from q
where h.metric_date = q.md;
