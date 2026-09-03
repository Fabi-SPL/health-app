-- v130: Sleep-inertia damper on the continuous Body Battery.
-- The autonomic integral (v129) reads HR/HRV — which say "recovered" even when you wake
-- groggy. Sleep inertia is a CNS/circadian thing HR/HRV can't see. This overlay knocks the
-- battery down for ~90 min after wake (scaled by how hard the wake was), decaying as you
-- actually come online. Makes the number match "how I feel RIGHT NOW", incl. morning fog.
-- It's an overlay on top of the raw integral, NOT a return to the daily-points formula.

-- severity of this morning's inertia + the wake instant. One row (or none if no sleep today).
CREATE OR REPLACE FUNCTION public.body_battery_wake_inertia(p_user_id uuid, p_date date)
RETURNS TABLE(wake timestamptz, severity numeric) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE w timestamptz; sh numeric; deep numeric; woke_deep boolean;
BEGIN
  SELECT sleep_end, sleep_hours, deep_sleep_min INTO w, sh, deep
   FROM health_metrics WHERE user_id=p_user_id AND metric_date=p_date;
  IF w IS NULL THEN RETURN; END IF;

  -- did he surface straight out of deep sleep? (harder inertia)
  SELECT (mode() WITHIN GROUP (ORDER BY sleep_stage)) = 'deep' INTO woke_deep
   FROM realtime_health
   WHERE user_id=p_user_id AND recorded_at BETWEEN w - interval '15 min' AND w;

  wake := w;
  severity :=  10                                                   -- base fog
    + (CASE WHEN COALESCE(woke_deep,false) THEN 12 ELSE 0 END)      -- woke FROM deep = brutal
    + LEAST(16, GREATEST(0, (COALESCE(deep,143) - 160) / 6.0))      -- lots of deep = heavy surfacing
    + GREATEST(0, (COALESCE(sh,9) - 9.5) * 4)                       -- oversleep grogginess
    + GREATEST(0, (7 - COALESCE(sh,9)) * 5);                        -- short-sleep grogginess
  RETURN NEXT;
END;$$;

-- live "now" = autonomic integral (last 36h) minus the decaying inertia penalty
CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE base numeric; wk timestamptz; sev numeric; pen numeric := 0; mins numeric;
BEGIN
  SELECT value INTO base FROM body_battery_curve(p_user_id, now() - interval '36 hours', now())
   ORDER BY at DESC LIMIT 1;
  IF base IS NULL THEN RETURN NULL; END IF;

  SELECT wake, severity INTO wk, sev
   FROM body_battery_wake_inertia(p_user_id, (now() AT TIME ZONE 'Europe/Berlin')::date);
  IF wk IS NOT NULL THEN
    mins := EXTRACT(epoch FROM (now() - wk)) / 60.0;
    IF mins >= 0 AND mins < 90 THEN pen := sev * (1 - mins/90.0); END IF;  -- linear decay over 90min
  END IF;

  RETURN GREATEST(5, round(base - pen));
END;$$;

-- chart: same integral, with the inertia dip baked into the morning points (the "boot-up" ramp)
CREATE OR REPLACE FUNCTION public.body_battery_series(
  p_user_id uuid, p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date
) RETURNS TABLE(at timestamptz, value numeric) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
  WITH wi AS (SELECT wake, severity FROM body_battery_wake_inertia(p_user_id, p_date))
  SELECT c.at,
    GREATEST(5, round(
      c.value - COALESCE((
        SELECT wi.severity * (1 - (EXTRACT(epoch FROM (c.at - wi.wake)) / 60.0) / 90.0)
        FROM wi WHERE c.at >= wi.wake AND c.at < wi.wake + interval '90 min'
      ), 0)
    ))
  FROM body_battery_curve(
    p_user_id,
    (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin') - interval '36 hours',
    LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  ) c
  WHERE c.at >= (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  ORDER BY c.at;
$$;
