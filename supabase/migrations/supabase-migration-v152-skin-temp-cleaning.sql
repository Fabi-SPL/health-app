-- Skin-temperature cleaning (2026-07-08).
--
-- Skin temp started flowing live after the v141 BLE-drain fix, but produces
-- occasional garbage. Two distinct failure modes were observed, and a pure
-- "spike-and-revert" slew filter catches NEITHER, because the iOS app caches the
-- last decoded skin temp (skinTemperature @Published) and forward-fills it onto
-- EVERY heart-rate row. So one bad decode becomes a flat block for the whole day:
--
--   * Jul 3 2026: 273 rows all 41.5 C  -> physically impossible (worn wrist skin
--     temp never exceeds ~38). The only out-of-range value in all history.
--   * Jun 24 2026: 4238 rows all 38.3 C -> IN physiological range but stuck; the
--     surrounding days sit at ~35. An in-range forward-filled glitch.
--
-- Because the glitch never reverts intraday (it is a stuck block), an intraday
-- slew detector sees a flat line and finds nothing. The fix is two layers:
--
--   Layer 1 (ingestion gate): a BEFORE INSERT trigger nulls skin_temp outside a
--     wide physiological band [28, 39]. Not a tight clamp -- it only removes
--     physically-impossible values (kills 41.5), never a real fever (<=~38).
--   Layer 2 (daily cleaner): robust median of gated readings, then a cross-DAY
--     slew reject -- if the day's median jumps >2.5 C from the trailing 14-day
--     baseline (Jun 24's +3.3 signature), treat it as a stuck glitch -> NULL.
--     Real fevers move the skin-temp baseline <=~2 C, so they survive.
--
-- recompute_health_metrics then stamps the cleaned value, making Postgres the
-- single source of truth for health_metrics.skin_temp (was app-owned via PATCH).

-- ---------------------------------------------------------------------------
-- Layer 1: ingestion gate. Null physiologically-impossible skin_temp at the
-- door so realtime graphs + downstream detection never see 41.5. Keeps every
-- other sensor field on the row intact.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_skin_temp()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.skin_temp IS NOT NULL AND (NEW.skin_temp < 28 OR NEW.skin_temp > 39) THEN
    NEW.skin_temp := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_skin_temp ON public.realtime_health;
CREATE TRIGGER trg_guard_skin_temp
  BEFORE INSERT ON public.realtime_health
  FOR EACH ROW EXECUTE FUNCTION public.guard_skin_temp();

-- ---------------------------------------------------------------------------
-- Layer 2: daily cleaner. Returns the cleaned daily skin_temp, or NULL if the
-- day has no plausible reading / is a stuck glitch. STABLE, reads prior days
-- only (no self-reference with the recompute upsert that calls it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clean_skin_temp_day(p_user_id uuid, p_date date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  day_start timestamptz := ((p_date::text            || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin';
  day_end   timestamptz := (((p_date + 1)::text      || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin';
  lo    constant numeric := 28.0;   -- physiological floor: worn wrist skin temp is never below this
  hi    constant numeric := 39.0;   -- physiological ceiling: real skin temp maxes ~38; 41.5 = impossible
  slew  constant numeric := 2.5;    -- day-baseline jump above this = stuck glitch (fever moves <=~2)
  raw_med numeric;
  n_gated int;
  base    numeric;
BEGIN
  -- Layer 1 (defensive re-gate) + robust median of the day's plausible readings.
  SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY skin_temp)::numeric, 1),
         count(*)
    INTO raw_med, n_gated
  FROM realtime_health
  WHERE user_id = p_user_id
    AND recorded_at >= day_start AND recorded_at < day_end
    AND skin_temp IS NOT NULL
    AND skin_temp >= lo AND skin_temp <= hi;

  IF n_gated = 0 OR raw_med IS NULL THEN
    RETURN NULL;   -- e.g. Jul 3: every reading gated out -> no skin temp for the day
  END IF;

  -- Cross-day slew reject. Baseline = median of the trailing 14 days of already-
  -- plausible daily skin_temp (median is robust to a lingering outlier). A jump
  -- >2.5 C from that baseline is physiologically impossible for a true daily
  -- skin-temp change -> stuck forward-filled glitch -> NULL (day reads "no data"
  -- rather than a fabricated spike). Real slow fever drifts <=~2 C and survives.
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY skin_temp)
    INTO base
  FROM health_metrics
  WHERE user_id = p_user_id
    AND metric_date < p_date AND metric_date >= p_date - 14
    AND skin_temp IS NOT NULL AND skin_temp >= lo AND skin_temp <= hi;

  IF base IS NOT NULL AND abs(raw_med - base) > slew THEN
    RETURN NULL;
  END IF;

  RETURN raw_med;
END;
$function$;

-- ---------------------------------------------------------------------------
-- recompute_health_metrics: unchanged except it now stamps a cleaned skin_temp
-- in BOTH write branches (placeholder + full), making Postgres authoritative.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recompute_health_metrics(p_user_id uuid, p_target_date date DEFAULT NULL::date)
 RETURNS health_metrics
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  target_date         date;
  win                 record;
  s_score             numeric;
  r_score             numeric;
  result_row          health_metrics;
  has_open_alert      boolean;
  has_recent_backfill boolean;
  is_alcohol          boolean;
  st_clean            numeric;
BEGIN
  target_date := COALESCE(p_target_date, (now() AT TIME ZONE 'Europe/Berlin')::date);

  -- v106: detect alcohol once, reuse for both sleep window + impact stamp
  SELECT detect_overnight_alcohol(p_user_id, target_date) INTO is_alcohol;

  -- v152: cleaned daily skin temp (physiological gate + cross-day slew reject)
  st_clean := clean_skin_temp_day(p_user_id, target_date);

  -- 1. Detect sleep window (alcohol-aware via v106)
  SELECT * INTO win FROM detect_sleep_window(p_user_id, target_date);

  -- Confidence floor: need 4+ hours of measured sleep to overwrite an existing row.
  IF win.o_sleep_start IS NULL OR COALESCE(win.o_asleep_min, 0) < 240 THEN
    -- v104: defer NULL-placeholder writes if a BLE sync is in flight
    SELECT EXISTS (
      SELECT 1 FROM ble_freshness_alerts
      WHERE user_id = p_user_id AND state = 'open'
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
      RETURN result_row;
    END IF;

    -- Insert empty placeholder if no row exists yet, but never overwrite a real one.
    -- v152: skin_temp is pg-owned; refresh it here too (it is not sleep data, so it
    -- is safe to update even on the low-confidence path).
    INSERT INTO health_metrics (user_id, metric_date, source, alcohol_impact, skin_temp)
    VALUES (p_user_id, target_date, 'pg_recompute', CASE WHEN is_alcohol THEN 1.0 ELSE NULL END, st_clean)
    ON CONFLICT (user_id, metric_date) DO UPDATE SET
      -- v137: clear stale flag on a sober verdict too (was: keep old value, which made
      -- false positives STICKY on low-sleep nights -- they never cleared). Safe because
      -- detect_overnight_alcohol is a pure function of append-only realtime_health: a real
      -- drunk night stays detected on every rerun (its data never disappears), so only stale
      -- FALSE positives clear here. Alcohol is computed from HR/HRV directly, so it is correctly
      -- decoupled from the sleep-confidence floor above.
      alcohol_impact = CASE WHEN is_alcohol THEN 1.0 ELSE NULL END,
      skin_temp      = EXCLUDED.skin_temp;

    SELECT * INTO result_row FROM health_metrics
    WHERE user_id = p_user_id AND metric_date = target_date;
    RETURN result_row;
  END IF;

  -- 2. Compute scores
  s_score := compute_sleep_score(
    win.o_total_min, win.o_asleep_min, win.o_deep_min, win.o_rem_min, win.o_efficiency_pct
  );
  r_score := compute_recovery_score(
    p_user_id, win.o_hrv_avg, win.o_resting_hr, s_score
  );

  -- 3. Upsert (now with alcohol_impact stamp + v152 cleaned skin_temp)
  INSERT INTO health_metrics (
    user_id, metric_date, source,
    sleep_start, sleep_end, sleep_hours,
    deep_sleep_min, rem_sleep_min, light_sleep_min, awake_min,
    sleep_efficiency_pct, sleep_score, recovery_score,
    hrv_avg, resting_hr,
    readiness_level, readiness_score, alcohol_impact, skin_temp
  )
  VALUES (
    p_user_id, target_date, 'pg_recompute',
    win.o_sleep_start, win.o_sleep_end,
    ROUND(win.o_asleep_min / 60.0, 1),
    win.o_deep_min, win.o_rem_min, win.o_light_min, win.o_awake_min,
    win.o_efficiency_pct, s_score, r_score,
    win.o_hrv_avg, win.o_resting_hr,
    CASE WHEN r_score >= 67 THEN 'green'
         WHEN r_score >= 34 THEN 'yellow'
         ELSE 'red' END,
    r_score,
    CASE WHEN is_alcohol THEN 1.0 ELSE NULL END,
    st_clean
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
    alcohol_impact = EXCLUDED.alcohol_impact,
    skin_temp = EXCLUDED.skin_temp;

  SELECT * INTO result_row FROM health_metrics
  WHERE user_id = p_user_id AND metric_date = target_date;
  RETURN result_row;
END;
$function$;

-- ---------------------------------------------------------------------------
-- Backfill: scrub the two identified garbage blocks from realtime_health, then
-- re-derive the affected health_metrics.skin_temp rows from the cleaned source.
-- ---------------------------------------------------------------------------
-- Jul 3: out-of-gate 41.5 block (all-history only out-of-range value).
UPDATE realtime_health SET skin_temp = NULL
WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'
  AND skin_temp IS NOT NULL AND (skin_temp < 28 OR skin_temp > 39);

-- Jun 23-24: in-range stuck 38.3 forward-fill (neighbors ~35; identified as glitch).
UPDATE realtime_health SET skin_temp = NULL
WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'
  AND skin_temp = 38.3
  AND recorded_at >= '2026-06-23 00:00:00+02' AND recorded_at < '2026-06-25 00:00:00+02';

-- Re-derive the daily rollup for the affected days from the now-cleaned source.
UPDATE health_metrics
SET skin_temp = clean_skin_temp_day(user_id, metric_date)
WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'
  AND metric_date IN ('2026-06-24', '2026-07-03');
