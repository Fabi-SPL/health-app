-- v179 — make a capture failure loud within the hour instead of visible weeks later
--
-- The v178 fault ran for weeks. Every piece of evidence existed the whole time
-- (995 upload_stall rows in bridge_logs, coverage at 56%), but nothing routed any
-- of it to a place Fabi would see, so the only signal was the morning card saying
-- "30% captured" with no cause attached.
--
-- This watchdog closes that loop: if the strap is connected but rows are not
-- landing, or the client is reporting upload failures, it queues a notification
-- that drain_notification_queue() (v173) sweeps into nudges within 2 minutes.
--
-- Deliberately NOT alerting when the strap is simply off the wrist or out of
-- range: that is a normal state, not a fault, and alerting on it would train the
-- alarm to be ignored.

CREATE OR REPLACE FUNCTION public.health_write_watchdog()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  v_user uuid := '372210e5-1dda-41b3-b759-5ff72293b8ff';
  v_win interval := interval '30 minutes';
  v_expected int := 60;          -- ~10s cadence over 30 min, minus slack
  v_rows int;
  v_stalls int;
  v_trigfails int;
  v_connected boolean;
  v_last_sample timestamptz;
  v_reason text;
BEGIN
  SELECT count(*) INTO v_rows
  FROM realtime_health
  WHERE user_id = v_user AND recorded_at > now() - v_win;

  SELECT count(*) INTO v_stalls
  FROM bridge_logs
  WHERE key = 'upload_stall' AND created_at > now() - v_win;

  SELECT count(*) INTO v_trigfails
  FROM bridge_logs
  WHERE key = 'trigger_failure' AND created_at > now() - v_win;

  SELECT strap_connected, last_ble_sample_at
  INTO v_connected, v_last_sample
  FROM current_state WHERE user_id = v_user;

  -- a server-side trigger fault is always a bug, strap state is irrelevant
  IF v_trigfails > 0 THEN
    v_reason := format('%s trigger failures in 30 min — a derived-state function is throwing', v_trigfails);
  -- client says it cannot upload
  ELSIF v_stalls >= 10 THEN
    v_reason := format('%s upload failures in 30 min — the phone has data it cannot write', v_stalls);
  -- strap reporting recently but rows are not arriving
  ELSIF v_connected AND v_last_sample > now() - interval '10 minutes' AND v_rows < v_expected / 3 THEN
    v_reason := format('strap is connected but only %s rows landed in 30 min (expected ~%s)', v_rows, v_expected);
  ELSE
    RETURN 'ok rows=' || v_rows || ' stalls=' || v_stalls || ' trigfails=' || v_trigfails;
  END IF;

  -- one alarm per 3h; a repeating alarm trains you to ignore it
  IF EXISTS (
    SELECT 1 FROM notification_queue
    WHERE user_id = v_user AND type = 'health_write_alarm'
      AND created_at > now() - interval '3 hours'
  ) THEN
    RETURN 'suppressed (cooldown): ' || v_reason;
  END IF;

  INSERT INTO notification_queue (user_id, type, title, body, scheduled_for, priority, context_data)
  VALUES (v_user, 'health_write_alarm',
          'health capture is dropping data',
          v_reason,
          now(), 'high',
          jsonb_build_object('rows_30m', v_rows, 'upload_stalls_30m', v_stalls,
                             'trigger_failures_30m', v_trigfails,
                             'strap_connected', v_connected));

  RETURN 'ALARM: ' || v_reason;
END $fn$;

SELECT cron.schedule('health_write_watchdog', '*/15 * * * *',
                     'SELECT public.health_write_watchdog()');
