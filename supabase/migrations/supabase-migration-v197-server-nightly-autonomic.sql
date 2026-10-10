-- v197: the nightly autonomic columns are computed on the server from the strap's own beats.
-- Until now nine of them had no server writer: the app PATCHed a live 30-beat snapshot whenever it synced
-- (respiratory 8.1-24.9, pNN50 in 1/29 steps, SD1 89.5 > RMSSD, sleep debt 17-29 h, cognitive pinned at 78).
-- nightly_autonomic: per 5-min segment RMSSD/SDNN/pNN50/SD1/SD2 inside the sleep window (median), strap resp
--   median, nocturnal HR dip vs the 13 h before sleep, DFA a1 from dfa_nocturnal_nightly, 7-night sleep debt
--   vs his own optimum (2 h/night cap), Uth VO2max (Tanaka HRmax, 30-night RHR), cognitive capacity vs his
--   prior 30 complete nights. NULL wherever the night cannot support the value.
-- recompute_health_metrics: writes those columns on every run; NULLs them on nights with no window.
-- guard_server_owned_nightly: the app's PATCH no longer overwrites them (no app build needed).
-- Rollback: supabase-migration-v197-rollback.sql

CREATE OR REPLACE FUNCTION public.nightly_autonomic(p_user_id uuid, p_date date)
 RETURNS TABLE(o_resp numeric, o_rmssd_rr numeric, o_sdnn numeric, o_pnn50 numeric, o_sd1 numeric, o_sd2 numeric,
               o_sd_ratio numeric, o_n_segments int, o_hr_dip numeric, o_dfa numeric, o_debt_h numeric, o_vo2 numeric,
               o_cog numeric, o_cog_label text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s timestamptz; e timestamptz; v_hrv numeric; v_sleep_h numeric; v_ok boolean;
  v_day_hr float8; v_day_n int; v_night_hr float8;
  v_base numeric; v_age numeric; v_rhr_med float8;
  sh_mu float8; sh_sd float8; lh_mu float8; lh_sd float8; sdnn_med float8;
  c_sleep float8; c_rmssd float8; c_sdnn float8; c_dfa float8; cap float8;
BEGIN
  SELECT sleep_start, sleep_end, hrv_avg, sleep_hours, COALESCE(sleep_complete, false)
    INTO s, e, v_hrv, v_sleep_h, v_ok
  FROM health_metrics WHERE user_id = p_user_id AND metric_date = p_date;

  IF NOT FOUND OR NOT v_ok OR s IS NULL OR e IS NULL OR e <= s THEN
    RETURN NEXT;   -- no observed night: one all-NULL row, the caller writes NULLs
    RETURN;
  END IF;

  -- Beat-to-beat metrics
  WITH beats AS (
    SELECT r.recorded_at, b.ord, b.rr::float8 AS rr
    FROM realtime_health r
    CROSS JOIN LATERAL unnest(r.rr_intervals) WITH ORDINALITY b(rr, ord)
    WHERE r.user_id = p_user_id AND r.recorded_at >= s AND r.recorded_at < e
      AND cardinality(r.rr_intervals) > 0
  ), seq AS (
    SELECT rr, floor(extract(epoch FROM recorded_at) / 300) AS seg,
           rr - lag(rr) OVER w AS dd, lag(rr) OVER w AS prv
    FROM beats WHERE rr BETWEEN 300 AND 2000
    WINDOW w AS (ORDER BY recorded_at, ord)
  ), segs AS (
    SELECT sqrt(avg(dd * dd)) AS rmssd, stddev_samp(rr) AS sdnn,
           100.0 * avg((abs(dd) > 50)::int) AS pnn50, sqrt(var_samp(dd) / 2) AS sd1
    FROM seq WHERE prv IS NOT NULL AND abs(dd) <= 0.2 * prv
    GROUP BY seg HAVING count(*) >= 150
  )
  SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY rmssd)::numeric, 1),
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sdnn)::numeric, 1),
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY pnn50)::numeric, 1),
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sd1)::numeric, 1),
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sqrt(GREATEST(0, 2 * sdnn * sdnn - sd1 * sd1)))::numeric, 1),
         count(*)::int
    INTO o_rmssd_rr, o_sdnn, o_pnn50, o_sd1, o_sd2, o_n_segments
  FROM segs;
  IF COALESCE(o_n_segments, 0) < 12 THEN       -- under 1 h of clean beats: not a night value
    o_rmssd_rr := NULL; o_sdnn := NULL; o_pnn50 := NULL; o_sd1 := NULL; o_sd2 := NULL;
  END IF;
  o_sd_ratio := CASE WHEN o_sd1 > 0 THEN round(o_sd2 / o_sd1, 2) END;

  SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY respiratory_rate)::numeric, 1)
    INTO o_resp
  FROM realtime_health
  WHERE user_id = p_user_id AND recorded_at >= s AND recorded_at < e
    AND respiratory_rate BETWEEN 6 AND 30;

  -- Nocturnal HR dip
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hr), count(*)
    INTO v_day_hr, v_day_n
  FROM (SELECT avg(heart_rate) hr FROM realtime_health
        WHERE user_id = p_user_id AND recorded_at >= s - interval '14 hours' AND recorded_at < s - interval '1 hour'
          AND heart_rate BETWEEN 30 AND 220
        GROUP BY date_trunc('minute', recorded_at) HAVING count(*) >= 20) m;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hr)
    INTO v_night_hr
  FROM (SELECT avg(heart_rate) hr FROM realtime_health
        WHERE user_id = p_user_id AND recorded_at >= s AND recorded_at < e
          AND heart_rate BETWEEN 30 AND 220
        GROUP BY date_trunc('minute', recorded_at) HAVING count(*) >= 20) m;
  IF v_day_n >= 240 AND v_day_hr > 0 AND v_night_hr > 0 THEN
    o_hr_dip := round((100 * (v_day_hr - v_night_hr) / v_day_hr)::numeric, 1);
  END IF;

  SELECT round(dfa_core_median, 2) INTO o_dfa
  FROM dfa_nocturnal_nightly
  WHERE user_id = p_user_id AND night_date = p_date AND quality_flag = 'ok';

  -- Sleep debt, 7 nights ending this morning
  SELECT round(mu, 2) INTO v_base FROM personal_priors WHERE user_id = p_user_id AND param = 'optimal_sleep_hours';
  v_base := COALESCE(v_base, 8.0);
  SELECT CASE WHEN count(*) >= 3
              THEN round(sum(LEAST(2, GREATEST(0, v_base - sleep_hours))) * 7.0 / count(*), 1) END
    INTO o_debt_h
  FROM health_metrics
  WHERE user_id = p_user_id AND sleep_hours > 0 AND sleep_complete IS NOT FALSE AND excluded IS NOT TRUE
    AND metric_date BETWEEN p_date - 6 AND p_date;

  -- VO2max (Uth), RHR from complete nights only
  SELECT age INTO v_age FROM user_body_profile WHERE user_id = p_user_id;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY resting_hr) INTO v_rhr_med
  FROM health_metrics
  WHERE user_id = p_user_id AND resting_hr > 0 AND sleep_complete IS TRUE AND excluded IS NOT TRUE
    AND metric_date BETWEEN p_date - 29 AND p_date;
  IF v_age > 0 AND v_rhr_med > 0 THEN
    o_vo2 := round((15.3 * (208 - 0.7 * v_age) / v_rhr_med)::numeric, 1);
  END IF;

  -- Cognitive capacity on nightly inputs vs his own prior 30 complete nights
  SELECT avg(sleep_hours), stddev_samp(sleep_hours), avg(ln(hrv_avg)), stddev_samp(ln(hrv_avg)),
         percentile_cont(0.5) WITHIN GROUP (ORDER BY sdnn_avg) FILTER (WHERE sdnn_avg > 0)
    INTO sh_mu, sh_sd, lh_mu, lh_sd, sdnn_med
  FROM health_metrics
  WHERE user_id = p_user_id AND sleep_complete IS TRUE AND excluded IS NOT TRUE
    AND sleep_hours > 0 AND hrv_avg > 0
    AND metric_date >= p_date - 30 AND metric_date < p_date;

  IF v_sleep_h > 0 AND v_hrv > 0 AND sh_sd > 0.1 AND lh_sd > 0 THEN
    c_sleep := GREATEST(0, LEAST(100, 50 + ((v_sleep_h - sh_mu) / sh_sd) * 25));
    c_rmssd := GREATEST(0, LEAST(100, 50 + ((ln(v_hrv) - lh_mu) / GREATEST(lh_sd, 0.01)) * 25));
    c_sdnn  := CASE WHEN o_sdnn > 0 AND sdnn_med > 0 THEN LEAST(100, LEAST(o_sdnn / sdnn_med, 1.5) * 100) ELSE 50 END;
    c_dfa   := CASE WHEN o_dfa IS NULL THEN 50
                    WHEN o_dfa BETWEEN 0.9 AND 1.2 THEN 100
                    -- app had no branch above 1.2: 1.4 gave 233 points. Held at 100 here (needs a citation).
                    WHEN o_dfa >= 0.75 THEN 60 + (LEAST(o_dfa, 0.9) - 0.75) / 0.15 * 40
                    ELSE GREATEST(0, o_dfa / 0.75 * 60) END;
    cap := c_sleep * 0.45 + c_rmssd * 0.25 + c_sdnn * 0.15 + c_dfa * 0.15;
    o_cog := round(cap::numeric);
    o_cog_label := CASE WHEN cap >= 80 THEN 'Full' WHEN cap >= 50 THEN 'Reduced' ELSE 'Low' END;
  END IF;

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
  na                  record;
BEGIN
  -- v197: the nightly autonomic columns are server-owned; the guard trigger only lets this transaction write them.
  PERFORM set_config('lucid.server_write', 'on', true);
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
      readiness_score = NULL, readiness_level = NULL, hrv_avg = NULL, resting_hr = NULL,
      -- v197: no observed night, no nightly autonomic values (the phone's daytime snapshot is not a night).
      respiratory_rate = NULL, sdnn_avg = NULL, pnn50_avg = NULL, dfa_alpha1_avg = NULL,
      poincare_sd1 = NULL, poincare_sd2 = NULL, poincare_ratio = NULL, nocturnal_hr_dip = NULL,
      sleep_debt_hours = NULL, vo2max_estimate = NULL, cognitive_capacity_score = NULL, cognitive_label = NULL;

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

  -- v197: nightly autonomic metrics from the strap's own beats inside the window (NULL when not observed).
  SELECT * INTO na FROM nightly_autonomic(p_user_id, target_date);
  UPDATE health_metrics SET
    respiratory_rate = na.o_resp, sdnn_avg = na.o_sdnn, pnn50_avg = na.o_pnn50, dfa_alpha1_avg = na.o_dfa,
    poincare_sd1 = na.o_sd1, poincare_sd2 = na.o_sd2, poincare_ratio = na.o_sd_ratio, nocturnal_hr_dip = na.o_hr_dip,
    sleep_debt_hours = na.o_debt_h, vo2max_estimate = na.o_vo2,
    cognitive_capacity_score = na.o_cog, cognitive_label = na.o_cog_label
  WHERE user_id = p_user_id AND metric_date = target_date;

  SELECT * INTO result_row FROM health_metrics
  WHERE user_id = p_user_id AND metric_date = target_date;
  RETURN result_row;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_server_owned_nightly()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF current_setting('lucid.server_write', true) IS DISTINCT FROM 'on' THEN
    NEW.respiratory_rate         := OLD.respiratory_rate;
    NEW.sdnn_avg                 := OLD.sdnn_avg;
    NEW.pnn50_avg                := OLD.pnn50_avg;
    NEW.dfa_alpha1_avg           := OLD.dfa_alpha1_avg;
    NEW.poincare_sd1             := OLD.poincare_sd1;
    NEW.poincare_sd2             := OLD.poincare_sd2;
    NEW.poincare_ratio           := OLD.poincare_ratio;
    NEW.nocturnal_hr_dip         := OLD.nocturnal_hr_dip;
    NEW.sleep_debt_hours         := OLD.sleep_debt_hours;
    NEW.vo2max_estimate          := OLD.vo2max_estimate;
    NEW.cognitive_capacity_score := OLD.cognitive_capacity_score;
    NEW.cognitive_label          := OLD.cognitive_label;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_server_owned_nightly ON public.health_metrics;
CREATE TRIGGER trg_guard_server_owned_nightly
  BEFORE UPDATE ON public.health_metrics
  FOR EACH ROW EXECUTE FUNCTION public.guard_server_owned_nightly();
