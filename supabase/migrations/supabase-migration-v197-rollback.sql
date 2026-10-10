-- v197 rollback: recompute_health_metrics as of v193, guard and nightly_autonomic removed
DROP TRIGGER IF EXISTS trg_guard_server_owned_nightly ON public.health_metrics;
DROP FUNCTION IF EXISTS public.guard_server_owned_nightly();

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

    -- v193: only a recent night can still be filled by a sync; an old date was blocked for no reason.
    IF (has_open_alert OR has_recent_backfill)
       AND target_date >= (now() AT TIME ZONE 'Europe/Berlin')::date - 4 THEN
      RAISE NOTICE 'recompute_health_metrics: sync in flight for %, deferring (alert=% backfill=%)',
        p_user_id, has_open_alert, has_recent_backfill;
      SELECT * INTO result_row FROM health_metrics
      WHERE user_id = p_user_id AND metric_date = target_date;
      IF result_row.metric_date IS NULL THEN RETURN NULL; END IF;
      RETURN result_row;
    END IF;

    -- v190: a night with no usable window still says why. An empty row read as "didn't sleep".
    SELECT * INTO q FROM sleep_window_quality(p_user_id, target_date, NULL, NULL, COALESCE(win.o_asleep_min, 0));

    INSERT INTO health_metrics (user_id, metric_date, source, alcohol_impact, skin_temp,
                                sleep_complete, sleep_incomplete_reason, sleep_coverage_pct,
                                sleep_max_gap_min, sleep_measured_min)
    VALUES (p_user_id, target_date, 'pg_recompute', CASE WHEN is_alcohol THEN 1.0 ELSE NULL END, st_clean,
            false, q.o_reason, q.o_coverage_pct, q.o_max_gap_min, win.o_asleep_min)
    ON CONFLICT (user_id, metric_date) DO UPDATE SET
      alcohol_impact = CASE WHEN is_alcohol THEN 1.0 ELSE health_metrics.alcohol_impact END,
      skin_temp      = COALESCE(EXCLUDED.skin_temp, health_metrics.skin_temp),
      sleep_complete = false,
      sleep_incomplete_reason = EXCLUDED.sleep_incomplete_reason,
      sleep_coverage_pct = EXCLUDED.sleep_coverage_pct,
      sleep_max_gap_min = EXCLUDED.sleep_max_gap_min,
      sleep_measured_min = EXCLUDED.sleep_measured_min,
      -- v193: a night that no longer has a window must not keep an older run's bedtime (06-13 kept 19:00).
      sleep_start = NULL, sleep_end = NULL, sleep_hours = NULL,
      deep_sleep_min = NULL, rem_sleep_min = NULL, light_sleep_min = NULL, awake_min = NULL,
      sleep_efficiency_pct = NULL, sleep_score = NULL, recovery_score = NULL,
      readiness_score = NULL, readiness_level = NULL, hrv_avg = NULL, resting_hr = NULL;

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

DROP FUNCTION IF EXISTS public.nightly_autonomic(uuid, date);
