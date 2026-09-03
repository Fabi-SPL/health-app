-- v121: Body Battery — smooth proportional drain + 24h series + anti-inflation guard
-- Problem this fixes:
--   (a) FLUCTUATION (7→87→5): old on-device engine on stale app builds wrote inflated
--       values. The trigger below makes it physically impossible for any app build to
--       store body_battery above the daily anchor — server owns the column, period.
--   (b) STUCK-AT-5: old drain was absolute points (1.2*hrs + 0.12*bpm_hrs ≈ 44) which
--       exceeded a depleted-day anchor (≈22) → instant floor by noon. New model scales
--       drain as a FRACTION of the anchor, so it glides smoothly and never cliffs.

-- 1. Pure helper: proportional smooth drain. value(wake)=anchor; monotonic ↓ over the day.
--    Time-of-day drain (caps at 0.75 so time alone never empties past 25%) + a saturating
--    exertion term (up to +0.20 for very active days). Total drained capped at 0.88.
CREATE OR REPLACE FUNCTION public.body_battery_value(
  p_anchor numeric, p_waking_h numeric, p_bpm_hours numeric
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(5, round(
    p_anchor * (1 - LEAST(0.88::numeric,
        LEAST(0.75::numeric, GREATEST(0, p_waking_h) / 17.0)
      + 0.20 * (1 - exp(-GREATEST(0, p_bpm_hours) / 45.0))
    ))
  )::numeric);
$$;

-- 2. Live "now" = anchor scaled by smooth drain (was: anchor − absolute_drain).
CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE anchor numeric; floor_hr numeric; wake timestamptz; waking_h numeric; bpm_hours numeric;
BEGIN
  anchor := body_battery_anchor_today(p_user_id);
  IF anchor IS NULL THEN RETURN NULL; END IF;

  SELECT median INTO floor_hr FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  floor_hr := COALESCE(floor_hr, 50);

  SELECT sleep_end INTO wake FROM health_metrics
   WHERE user_id=p_user_id AND metric_date=(now() AT TIME ZONE 'Europe/Berlin')::date;
  IF wake IS NULL OR wake > now() THEN wake := now() - interval '14 hours'; END IF;

  waking_h := GREATEST(0, EXTRACT(epoch FROM (now() - wake))/3600.0);
  SELECT COALESCE(sum(GREATEST(0, heart_rate - floor_hr)),0)*10.0/3600.0 INTO bpm_hours
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate>30 AND recorded_at>=wake AND recorded_at<=now();

  RETURN body_battery_value(anchor, waking_h, COALESCE(bpm_hours,0));
END;$$;

-- 3. 24h reconstructed curve for the in-app chart. Same helper as body_battery_now, so
--    the curve's endpoint == the big number on screen. Rebuilt each call from realtime HR.
CREATE OR REPLACE FUNCTION public.body_battery_series(
  p_user_id uuid, p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date
) RETURNS TABLE(at timestamptz, value numeric) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE anchor numeric; floor_hr numeric; wake timestamptz; tend timestamptz;
BEGIN
  SELECT body_battery_anchor INTO anchor FROM health_metrics
   WHERE user_id=p_user_id AND metric_date=p_date;
  IF anchor IS NULL THEN RETURN; END IF;

  SELECT median INTO floor_hr FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  floor_hr := COALESCE(floor_hr, 50);

  SELECT sleep_end INTO wake FROM health_metrics WHERE user_id=p_user_id AND metric_date=p_date;
  IF wake IS NULL THEN
    wake := ((p_date::text || ' 08:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin';
  END IF;

  tend := LEAST(now(), ((p_date::text || ' 23:45:00')::timestamp) AT TIME ZONE 'Europe/Berlin');
  IF tend <= wake THEN RETURN; END IF;

  RETURN QUERY
  WITH ticks AS (SELECT generate_series(wake, tend, interval '15 min') AS t),
  buckets AS (
    SELECT date_bin('15 min', recorded_at, wake) AS bkt,
           sum(GREATEST(0, heart_rate - floor_hr)) AS s
    FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate>30 AND recorded_at>=wake AND recorded_at<=tend
    GROUP BY 1
  )
  SELECT tk.t,
    body_battery_value(
      anchor,
      EXTRACT(epoch FROM (tk.t - wake))/3600.0,
      COALESCE((SELECT sum(b.s) FROM buckets b WHERE b.bkt <= tk.t), 0)*10.0/3600.0
    )
  FROM ticks tk ORDER BY tk.t;
END;$$;

-- 4. Anti-inflation guard. ANY write (any app build, any path) that tries to store
--    body_battery above the daily anchor gets clamped to the anchor. The */15 cron then
--    refines to the precise live value. The 87 can never be stored again.
CREATE OR REPLACE FUNCTION public.clamp_body_battery() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_anchor numeric;
BEGIN
  IF NEW.body_battery IS NULL THEN RETURN NEW; END IF;
  v_anchor := COALESCE(NEW.body_battery_anchor, OLD.body_battery_anchor);
  IF v_anchor IS NULL AND NEW.metric_date = (now() AT TIME ZONE 'Europe/Berlin')::date THEN
    v_anchor := body_battery_anchor_today(NEW.user_id);
  END IF;
  IF v_anchor IS NULL THEN RETURN NEW; END IF;
  IF NEW.body_battery > v_anchor THEN
    NEW.body_battery := round(v_anchor);
  END IF;
  RETURN NEW;
END;$$;

DROP TRIGGER IF EXISTS trg_clamp_body_battery ON health_metrics;
CREATE TRIGGER trg_clamp_body_battery
  BEFORE INSERT OR UPDATE OF body_battery ON health_metrics
  FOR EACH ROW EXECUTE FUNCTION clamp_body_battery();
