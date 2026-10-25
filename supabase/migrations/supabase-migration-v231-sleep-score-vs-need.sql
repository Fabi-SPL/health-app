-- v231 - The sleep score's duration part is measured against his own need, not a fixed 7-9 h band.
--
-- compute_sleep_need (healing + debt + load, the number the plan and the alarm use) put his need at 8.2-9.5 h on
-- every scored night since 08-25, while the score gave full duration marks from 7 h. 21 of 44 nights were an hour
-- or more under the need. Prior art: WHOOP scores sleep as hours slept against hours needed.
-- Now: full marks from need - 0.5 h, the old 30 points per hour below that, oversleep from need + 1 h (never
-- past 10 h). Without a need (NULL) the function keeps the old band.
-- Replay 08-25..10-25 (44 scored nights, recovery replica exact on 44/44): correlation of the score with
-- (asleep - need) 0.22 -> 0.75; mean sleep score 80.3 -> 75.2; largest change -17 (10-17, 6.8 h vs 9.1 h need).
-- Recovery reads the sleep score, so it moves on 35 nights, at most 11 points. Past rows are not rewritten.
-- Rollback: supabase-migration-v231-rollback.sql

BEGIN;

DROP FUNCTION public.compute_sleep_score(integer, integer, integer, integer, integer, numeric);

CREATE OR REPLACE FUNCTION public.compute_sleep_score(p_total_minutes integer, p_asleep_minutes integer, p_deep_min integer, p_rem_min integer, p_efficiency_pct integer, p_consistency numeric DEFAULT NULL::numeric, p_need_h numeric DEFAULT NULL::numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  w_duration    numeric := 0.35;
  w_efficiency  numeric := 0.25;
  w_stage       numeric := 0.20;
  w_consistency numeric := 0.20;
  duration_hours numeric;
  duration_score numeric;
  efficiency_score numeric;
  deep_pct numeric;
  rem_pct numeric;
  deep_score numeric;
  rem_score numeric;
  stage_score numeric;
  total_score numeric;
BEGIN
  IF p_asleep_minutes IS NULL OR p_asleep_minutes = 0 THEN RETURN 0; END IF;

  duration_hours := p_asleep_minutes / 60.0;

  -- v231: with a need, a night is full from need - 0.5 h and oversleep starts at need + 1 h (never past 10 h);
  -- the 30/h slope below the floor is the old band's. Without one, the old fixed 7-9 h band.
  IF p_need_h IS NOT NULL AND p_need_h > 0 THEN
    IF duration_hours >= p_need_h - 0.5 THEN
      duration_score := CASE WHEN duration_hours > LEAST(10, p_need_h + 1)
                             THEN GREATEST(60, 100 - (duration_hours - LEAST(10, p_need_h + 1)) * 20) ELSE 100 END;
    ELSIF duration_hours >= p_need_h - 2.5 THEN
      duration_score := 100 - ((p_need_h - 0.5) - duration_hours) * 30;
    ELSE
      duration_score := GREATEST(0, 40 * duration_hours / GREATEST(p_need_h - 2.5, 0.1));
    END IF;
  ELSIF duration_hours BETWEEN 7 AND 9 THEN
    duration_score := 100;
  ELSIF duration_hours > 9 THEN
    -- v153: oversleep tier must precede the >=6 ramp or it runs unbounded.
    duration_score := GREATEST(60, 100 - (duration_hours - 9) * 20);
  ELSIF duration_hours >= 6 THEN
    duration_score := 70 + (duration_hours - 6) * 30;
  ELSIF duration_hours >= 5 THEN
    duration_score := 40 + (duration_hours - 5) * 30;
  ELSE
    duration_score := GREATEST(duration_hours / 5.0 * 40, 0);
  END IF;

  IF p_efficiency_pct >= 90 THEN
    efficiency_score := 100;
  ELSIF p_efficiency_pct >= 80 THEN
    efficiency_score := 70 + (p_efficiency_pct - 80) * 3;
  ELSE
    efficiency_score := GREATEST(p_efficiency_pct / 80.0 * 70, 0);
  END IF;

  -- v176: deep band moved 18-30 -> 13-23, centre 23 -> 18. The old band was fitted to the
  -- 30% quota's output, not to physiology.
  deep_pct := (p_deep_min::numeric / p_asleep_minutes) * 100;
  rem_pct  := (p_rem_min::numeric  / p_asleep_minutes) * 100;
  deep_score := CASE WHEN deep_pct BETWEEN 13 AND 23 THEN 100
                     ELSE GREATEST(0, 100 - ABS(deep_pct - 18) * 5) END;
  rem_score  := CASE WHEN rem_pct  BETWEEN 20 AND 32 THEN 100
                     ELSE GREATEST(0, 100 - ABS(rem_pct - 26) * 5) END;
  stage_score := (deep_score + rem_score) / 2.0;

  -- v176: consistency is now measured (see recompute_health_metrics) or explicitly absent.
  -- COLD START: fewer than 5 prior nights of bedtime history -> we do not know, so drop the
  -- term and renormalise the remaining three weights. Silently substituting 50 was what
  -- clamped every score into [10, 90].
  IF p_consistency IS NULL THEN
    total_score := (duration_score   * w_duration
                  + efficiency_score * w_efficiency
                  + stage_score      * w_stage)
                 / (w_duration + w_efficiency + w_stage);
  ELSE
    total_score := duration_score    * w_duration
                 + efficiency_score  * w_efficiency
                 + stage_score       * w_stage
                 + p_consistency     * w_consistency;
  END IF;

  RETURN ROUND(LEAST(100, GREATEST(0, total_score)));
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
  na                  record;
  v_need              numeric;
BEGIN
  -- v197: the nightly autonomic columns are server-owned; the guard trigger only lets this transaction write them.
  PERFORM set_config('lucid.server_write', 'on', true);
  target_date := COALESCE(p_target_date, (now() AT TIME ZONE 'Europe/Berlin')::date);

  -- v209: his drinking tap counts here too, not only the detector. The detector reads the night's stages, which
  -- the server writes only after this point, so a flagged night could stage as a drinking night and still miss
  -- alcohol_impact (body battery, illness gate, sleep-need priors all read it).
  is_alcohol := drinking_flagged_night(p_user_id, target_date)
                OR COALESCE(detect_overnight_alcohol(p_user_id, target_date), false);
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
      readiness_score = NULL, readiness_level = NULL, hrv_avg = NULL, resting_hr = NULL,
      -- v197: no observed night, no nightly autonomic values (the phone's daytime snapshot is not a night).
      respiratory_rate = NULL, sdnn_avg = NULL, pnn50_avg = NULL, dfa_alpha1_avg = NULL,
      poincare_sd1 = NULL, poincare_sd2 = NULL, poincare_ratio = NULL, nocturnal_hr_dip = NULL,
      sleep_debt_hours = NULL, vo2max_estimate = NULL, cognitive_capacity_score = NULL, cognitive_label = NULL;

    -- v207: the stage chart shows the stages behind these totals once the night is over. Never fails the recompute.
    BEGIN
      PERFORM stamp_sleep_stages(p_user_id, target_date);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'stamp_sleep_stages failed for %: %', target_date, SQLERRM;
    END;

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
    -- v231: sleep duration is scored against the need the alarm used that night (its session's target_h,
    -- else compute_sleep_need for the morning), the same number as the plan and the alarm.
    SELECT s.target_h INTO v_need FROM smart_wake_sessions s
     WHERE s.user_id = p_user_id AND s.target_h IS NOT NULL
       AND s.armed_at >= ((target_date - 1)::timestamp + interval '12 hours') AT TIME ZONE 'Europe/Berlin'
       AND s.armed_at <  (target_date::timestamp + interval '8 hours') AT TIME ZONE 'Europe/Berlin'
     ORDER BY s.armed_at DESC LIMIT 1;
    IF v_need IS NULL THEN
      SELECT c.target_h INTO v_need FROM compute_sleep_need(p_user_id, target_date) c;
    END IF;
    s_score := compute_sleep_score(
      win.o_total_min, win.o_asleep_min, win.o_deep_min, win.o_rem_min,
      win.o_efficiency_pct, consistency, v_need);
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

  -- v197: nightly autonomic metrics from the strap's own beats inside the window (NULL when not observed).
  SELECT * INTO na FROM nightly_autonomic(p_user_id, target_date);
  UPDATE health_metrics SET
    respiratory_rate = na.o_resp, sdnn_avg = na.o_sdnn, pnn50_avg = na.o_pnn50, dfa_alpha1_avg = na.o_dfa,
    poincare_sd1 = na.o_sd1, poincare_sd2 = na.o_sd2, poincare_ratio = na.o_sd_ratio, nocturnal_hr_dip = na.o_hr_dip,
    sleep_debt_hours = na.o_debt_h, vo2max_estimate = na.o_vo2,
    cognitive_capacity_score = na.o_cog, cognitive_label = na.o_cog_label
  WHERE user_id = p_user_id AND metric_date = target_date;

  -- v207: the stage chart shows the stages behind these totals once the night is over. Never fails the recompute.
  BEGIN
    PERFORM stamp_sleep_stages(p_user_id, target_date);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'stamp_sleep_stages failed for %: %', target_date, SQLERRM;
  END;

  SELECT * INTO result_row FROM health_metrics
  WHERE user_id = p_user_id AND metric_date = target_date;
  RETURN result_row;
END;
$function$;

COMMIT;
