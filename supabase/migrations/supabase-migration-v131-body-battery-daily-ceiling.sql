-- v131: Daily ceiling — the waking day trends DOWN from your morning charge.
-- Bug it fixes: the pure integral (v129) let daytime rest charge ABOVE the wake level
-- (HRV spikes when you lie around -> battery climbed to 100 at noon on a rough morning).
-- A real body battery peaks at wake and declines through the day; rest only SLOWS the
-- decline, it doesn't make you fresher than you woke. So:
--   P (morning charge) = the integral's value at wake  (encodes the night: bad night -> low P)
--   ceiling(t) = P - 3/hr since wake
--   value = LEAST(integral, ceiling)  then minus the inertia dip
-- Still 100% raw-data: P is the actual overnight autonomic integral, not a formula.

-- live "now" = min(autonomic integral, declining daily ceiling) minus inertia
CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE base numeric; peak numeric; wk timestamptz; sev numeric; pen numeric := 0;
        mins numeric; ceil_now numeric; hrs numeric;
BEGIN
  SELECT value INTO base FROM body_battery_curve(p_user_id, now() - interval '36 hours', now())
   ORDER BY at DESC LIMIT 1;
  IF base IS NULL THEN RETURN NULL; END IF;

  SELECT wake, severity INTO wk, sev
   FROM body_battery_wake_inertia(p_user_id, (now() AT TIME ZONE 'Europe/Berlin')::date);

  IF wk IS NOT NULL AND now() > wk THEN
    -- P = charge at the moment you woke
    SELECT value INTO peak FROM body_battery_curve(p_user_id, wk - interval '36 hours', wk)
     ORDER BY at DESC LIMIT 1;
    hrs := EXTRACT(epoch FROM (now() - wk)) / 3600.0;
    ceil_now := COALESCE(peak, 100) - 3.0 * hrs;        -- decline 3 pts/hour from wake
    base := LEAST(base, ceil_now);
    mins := hrs * 60.0;
    IF mins < 90 THEN pen := sev * (1 - mins/90.0); END IF;
  END IF;

  RETURN GREATEST(5, round(base - pen));
END;$$;

-- chart: same ceiling + inertia baked into every point
CREATE OR REPLACE FUNCTION public.body_battery_series(
  p_user_id uuid, p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date
) RETURNS TABLE(at timestamptz, value numeric) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
  WITH wi AS (SELECT wake, severity FROM body_battery_wake_inertia(p_user_id, p_date)),
  curve AS (
    SELECT at, value FROM body_battery_curve(
      p_user_id,
      (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin') - interval '36 hours',
      LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
    )
  ),
  pk AS (  -- morning charge = integral value at/just before wake
    SELECT c.value AS p FROM curve c, wi WHERE c.at <= wi.wake ORDER BY c.at DESC LIMIT 1
  )
  SELECT c.at,
    GREATEST(5, round(
      LEAST(
        c.value,
        CASE WHEN wi.wake IS NOT NULL AND c.at > wi.wake
          THEN COALESCE((SELECT p FROM pk), 100) - 3.0 * EXTRACT(epoch FROM (c.at - wi.wake))/3600.0
          ELSE c.value END
      )
      - COALESCE((
          SELECT wi.severity * (1 - (EXTRACT(epoch FROM (c.at - wi.wake)) / 60.0) / 90.0)
          WHERE c.at >= wi.wake AND c.at < wi.wake + interval '90 min'
        ), 0)
    ))
  FROM curve c LEFT JOIN wi ON true
  WHERE c.at >= (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  ORDER BY c.at;
$$;
