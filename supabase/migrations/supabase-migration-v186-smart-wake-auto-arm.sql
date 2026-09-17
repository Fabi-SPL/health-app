-- v186: smart_wake_auto_arm — the alarm arms itself every evening.
-- Root cause of the missed mornings of Sep 16 + 17: arming was manual-only
-- (WindDownView tap). No tap, no session, cron had nothing to evaluate.
-- This arms a default session (no deadline) if none exists; an in-app arm
-- with an "up by" deadline supersedes it via arm_smart_wake's retire step.
CREATE OR REPLACE FUNCTION public.smart_wake_auto_arm()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  u uuid; armed_count int := 0; berlin_hour int;
BEGIN
  berlin_hour := EXTRACT(hour FROM now() AT TIME ZONE 'Europe/Berlin')::int;
  -- arm window: 20:00–02:59 Berlin
  IF NOT (berlin_hour >= 20 OR berlin_hour < 3) THEN RETURN 0; END IF;

  FOR u IN SELECT DISTINCT user_id FROM smart_wake_sessions
  LOOP
    -- any session touched in the last 12h (armed, fired, or user-cancelled)
    -- means tonight is already decided: never double-arm, never override a cancel.
    IF EXISTS (SELECT 1 FROM smart_wake_sessions s
                WHERE s.user_id = u AND s.armed_at > now() - interval '12 hours') THEN
      CONTINUE;
    END IF;
    PERFORM arm_smart_wake(u, NULL, 30);
    armed_count := armed_count + 1;
  END LOOP;
  RETURN armed_count;
END;$function$;
