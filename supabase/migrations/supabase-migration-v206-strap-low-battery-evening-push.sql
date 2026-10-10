-- v206: one push in the evening when the strap is below 20%.
-- On 2026-10-09 the strap ran flat at 20:30 and the night was lost. Fabi asked for a push the evening
-- before whenever the strap is under 20%. Runs every 5 min; acts only 18:00-23:59 Berlin, once per evening,
-- and stays quiet while the battery is rising (charging). The reading is the app's heartbeat, so a push
-- implies the app is alive to poll it. Priority 'visual' = time-sensitive banner with the Lucid sound.
-- p_test sends a clearly marked test right away, ignoring the clock and the threshold.

CREATE OR REPLACE FUNCTION public.strap_low_battery_check(p_user_id uuid, p_test boolean DEFAULT false)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_local timestamp := now() AT TIME ZONE 'Europe/Berlin';
  v_bat int;
  v_prev int;
  v_at timestamptz;
BEGIN
  IF NOT p_test AND extract(hour FROM v_local) < 18 THEN RETURN 'not evening'; END IF;

  SELECT h.strap_bat, h.at INTO v_bat, v_at
  FROM app_heartbeats(p_user_id, now() - interval '15 min', now()) h
  WHERE h.strap_bat > 0 ORDER BY h.at DESC LIMIT 1;
  IF v_bat IS NULL THEN RETURN 'no recent reading'; END IF;
  IF NOT p_test AND v_bat >= 20 THEN RETURN 'ok ' || v_bat || '%'; END IF;

  SELECT h.strap_bat INTO v_prev
  FROM app_heartbeats(p_user_id, now() - interval '30 min', now() - interval '10 min') h
  WHERE h.strap_bat > 0 ORDER BY h.at LIMIT 1;
  IF NOT p_test AND v_prev IS NOT NULL AND v_bat > v_prev THEN RETURN 'charging ' || v_prev || '->' || v_bat || '%'; END IF;

  IF NOT p_test AND EXISTS (
       SELECT 1 FROM nudges
       WHERE user_id = p_user_id AND metadata->>'kind' = 'strap_battery_low'
         AND (created_at AT TIME ZONE 'Europe/Berlin')::date = v_local::date) THEN
    RETURN 'already sent today';
  END IF;

  INSERT INTO nudges (user_id, title, message, deliver_at, priority, channels, status, source, metadata)
  VALUES (p_user_id,
          CASE WHEN p_test THEN 'Test: strap battery push' ELSE 'Charge your strap' END,
          CASE WHEN p_test
               THEN 'Test only. From 18:00 you get this once when the strap is under 20%. Right now it is at ' || v_bat || '%.'
               ELSE 'Strap at ' || v_bat || '%. Charge it before bed so tonight gets recorded.' END,
          now(), 'visual', ARRAY['push'], 'pending', 'health',
          jsonb_build_object('kind', CASE WHEN p_test THEN 'strap_battery_low_test' ELSE 'strap_battery_low' END,
                             'battery', v_bat, 'reading_at', v_at));
  RETURN 'sent ' || v_bat || '%';
END;
$function$;

SELECT cron.unschedule('strap_low_battery_evening') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'strap_low_battery_evening');
SELECT cron.schedule('strap_low_battery_evening', '*/5 * * * *',
  $$SELECT public.strap_low_battery_check('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)$$);
