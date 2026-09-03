-- v133: fold the full-metric daily adjustment (v132) into the morning charge.
-- P_final = clamp(P_autonomic_integral + daily_adjustment, 5, 100). The waking day's
-- ceiling declines from P_final. So every metric now shapes how charged you start the day:
-- great sleep/low RHR/no illness push it up; bad sleep/illness/alcohol/overtraining pull it
-- down. The live HR+HRV integral still drives moment-to-moment; this sets the daily envelope.

CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE base numeric; peak numeric; adj numeric; wk timestamptz; sev numeric; pen numeric := 0;
        mins numeric; ceil_now numeric; hrs numeric; d date;
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
    mins := hrs * 60.0;
    IF mins < 90 THEN pen := sev * (1 - mins/90.0); END IF;         -- inertia dip
  END IF;

  RETURN GREATEST(5, round(base - pen));
END;$$;

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
  pk AS (  -- morning charge = integral at wake + full-metric daily adjustment, clamped
    SELECT GREATEST(5, LEAST(100,
      (SELECT c.value FROM curve c, wi WHERE c.at <= wi.wake ORDER BY c.at DESC LIMIT 1)
      + body_battery_daily_adjustment(p_user_id, p_date)
    )) AS p
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
