-- v128: Body Battery BREATHES — live intraday recharge/drain (Fabi's "how I feel" metric)
-- Replaces the monotonic down-glide (v127) with a state integral from wake:
--   resting (HR at/below floor)  -> ticks UP gently   ("lay down and it climbs a bit")
--   active  (HR above floor)     -> drains, steeper the harder you push
-- Hard-capped at the daily anchor (your charge for the day) and floored at 5, so it
-- CAN'T run away like the old on-device 87 bug. Server-authoritative, app just displays.
--
-- NOTE: anchor enrichment (fragmentation/illness/sleep-debt) deliberately NOT added here —
-- those columns are null/sentinel/stale upstream; wiring them would inject noise. Separate fix.

-- The breathing curve: integrate rest/exertion over 5-min HR buckets from wake -> now.
-- Path-dependent (clamps each step), so it's a plpgsql loop, not a window sum.
CREATE OR REPLACE FUNCTION public.body_battery_curve(
  p_user_id uuid, p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date
) RETURNS TABLE(at timestamptz, value numeric) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE
  anchor numeric; floor_hr numeric; wake timestamptz; tend timestamptz;
  v numeric; prev_t timestamptz; r record; hr_rel numeric; rate numeric; dt numeric;
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
  tend := LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin');
  IF tend <= wake THEN RETURN; END IF;

  v := anchor;          -- start the day at full charge (the anchor)
  prev_t := wake;
  FOR r IN
    SELECT date_bin('5 min', recorded_at, wake) AS bkt, avg(heart_rate) AS hr
    FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate>30 AND recorded_at>=wake AND recorded_at<=tend
    GROUP BY 1 ORDER BY 1
  LOOP
    hr_rel := r.hr - floor_hr;                       -- how far above/below resting
    rate := CASE                                     -- battery points per MINUTE
      WHEN hr_rel < -2 THEN  0.16                     -- deep rest / nap -> recharge ~+10/h
      WHEN hr_rel <  3 THEN  0.04                     -- chilling at rest -> gentle UP +2.4/h
      WHEN hr_rel < 10 THEN -0.03                     -- sitting / light -> slow drain
      WHEN hr_rel < 25 THEN -(0.05 + 0.004 * hr_rel)  -- working / moving
      ELSE                  -(0.10 + 0.005 * hr_rel)  -- active / exercise -> steep
    END;
    dt := LEAST(15, GREATEST(0, EXTRACT(epoch FROM (r.bkt - prev_t)) / 60.0)); -- cap gaps at 15min
    IF dt = 0 THEN dt := 5; END IF;
    v := GREATEST(5, LEAST(anchor, v + rate * dt));  -- capped [5, anchor] -> can't run away
    prev_t := r.bkt;
    at := r.bkt; value := round(v);
    RETURN NEXT;
  END LOOP;
END;$$;

-- live "now" = the last point of today's breathing curve (fallback: anchor if no HR yet)
CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE v numeric;
BEGIN
  SELECT value INTO v FROM body_battery_curve(p_user_id) ORDER BY at DESC LIMIT 1;
  IF v IS NULL THEN v := body_battery_anchor_today(p_user_id); END IF;
  RETURN v;
END;$$;

-- series for the in-app 24h chart = the breathing curve (now goes up AND down)
CREATE OR REPLACE FUNCTION public.body_battery_series(
  p_user_id uuid, p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date
) RETURNS TABLE(at timestamptz, value numeric) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
  SELECT at, value FROM body_battery_curve(p_user_id, p_date) ORDER BY at;
$$;
