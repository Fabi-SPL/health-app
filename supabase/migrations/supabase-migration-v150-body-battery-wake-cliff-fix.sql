-- Body Battery morning-cliff fix (2026-07-03).
-- Problem: overnight curve recharged to 100, then at wake snapped to ~50 because
-- (a) the recovery-based "morning charge" (integral@wake + daily_adjustment) was only
-- applied AT wake, and (b) a wake-inertia "severity" penalty was subtracted ON TOP of
-- daily_adjustment = the same rough night docked twice. Result: 100 -> 50 cliff at wake.
-- Fix: overnight display converges to the morning charge (no overshoot -> no cliff);
-- drop the double-penalty. Daytime -3/h decline unchanged. Wake-inertia fn still used
-- for the wake TIME, just no longer subtracted from the value.

CREATE OR REPLACE FUNCTION public.body_battery_series(p_user_id uuid, p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Berlin'::text))::date)
 RETURNS TABLE(at timestamp with time zone, value numeric)
 LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  WITH wi AS (SELECT wake, severity FROM body_battery_wake_inertia(p_user_id, p_date)),
  curve AS (
    SELECT at, value FROM body_battery_curve(
      p_user_id,
      (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin') - interval '36 hours',
      LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
    )
  ),
  pk AS (  -- morning charge = integral at wake + full-metric daily adjustment, clamped
    SELECT GREATEST(5, LEAST(100,
      (SELECT c.value FROM curve c, wi WHERE c.at <= wi.wake ORDER BY c.at DESC LIMIT 1)
      + body_battery_daily_adjustment(p_user_id, p_date)
    )) AS p
  )
  SELECT c.at,
    GREATEST(5, round(
      CASE
        WHEN wi.wake IS NOT NULL AND c.at > wi.wake
          -- daytime: gentle -3/h decline from the recovery-adjusted morning charge
          THEN LEAST(c.value, COALESCE((SELECT p FROM pk), 100) - 3.0 * EXTRACT(epoch FROM (c.at - wi.wake))/3600.0)
        ELSE
          -- overnight: recharge, but capped at the day's morning charge so the line
          -- CONVERGES to the wake value instead of overshooting to 100 then snapping
          -- down. Kills the ~40-pt wake cliff. (Great-recovery nights: pk=100 -> no cap.)
          LEAST(c.value, COALESCE((SELECT p FROM pk), c.value))
      END
    ))
  FROM curve c LEFT JOIN wi ON true
  WHERE c.at >= (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  ORDER BY c.at;
$function$;

CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE base numeric; peak numeric; adj numeric; wk timestamptz; sev numeric;
        hrs numeric; ceil_now numeric; d date;
BEGIN
  SELECT value INTO base FROM body_battery_curve(p_user_id, now() - interval '36 hours', now())
   ORDER BY at DESC LIMIT 1;
  IF base IS NULL THEN RETURN NULL; END IF;

  d := (now() AT TIME ZONE 'Europe/Berlin')::date;
  SELECT wake, severity INTO wk, sev FROM body_battery_wake_inertia(p_user_id, d);

  IF wk IS NOT NULL AND now() > wk THEN
    SELECT value INTO peak FROM body_battery_curve(p_user_id, wk - interval '36 hours', wk)
     ORDER BY at DESC LIMIT 1;
    adj := body_battery_daily_adjustment(p_user_id, d);              -- full-metric stack
    peak := GREATEST(5, LEAST(100, COALESCE(peak,100) + COALESCE(adj,0)));
    hrs := EXTRACT(epoch FROM (now() - wk)) / 3600.0;
    ceil_now := peak - 3.0 * hrs;                                    -- decline through the day
    base := LEAST(base, ceil_now);
    -- v-fix 2026-07-03: removed the wake-inertia penalty (sev) here. daily_adjustment
    -- already docks the rough night; subtracting severity too was a double-penalty that,
    -- together with the overshoot-to-100, produced the jarring ~40-pt post-wake drop.
  END IF;

  RETURN GREATEST(5, round(base));
END;$function$;
