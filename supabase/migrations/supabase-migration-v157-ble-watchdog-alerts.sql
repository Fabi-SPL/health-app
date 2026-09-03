-- v157 — Make the BLE freshness watchdog actually WAKE SOMEONE UP.
--
-- 2026-08-04: the Whoop stream died at 22:03 and was still dead at 23:50.
-- `ble-freshness-watch` ran every single minute of that 107-minute outage,
-- succeeded every time, and sent nothing — because ble_freshness_check only
-- ever *recorded* episodes into ble_freshness_alerts. The comments in the old
-- body said "SILENT" twice. It was a logger wearing a watchdog's collar.
--
-- A stale stream at night costs the whole night's sleep data, which is the
-- single biggest lever on the Aug 2026 cut. That is worth a lockscreen banner.
--
-- Adds: notify on episode open, one escalation if it stays open, and a
-- louder night-window message (22:00-08:00) since that is when a gap is
-- most expensive and least likely to be noticed.

ALTER TABLE public.ble_freshness_alerts
  ADD COLUMN IF NOT EXISTS notified_at  timestamptz,
  ADD COLUMN IF NOT EXISTS escalated_at timestamptz;

CREATE OR REPLACE FUNCTION public.ble_freshness_check(p_threshold_min integer DEFAULT 10)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  r record;
  v_reason text;
  v_hour int;
  v_night boolean;
  v_id bigint;
BEGIN
  v_hour  := extract(hour FROM (now() AT TIME ZONE 'Europe/Berlin'));
  v_night := (v_hour >= 22 OR v_hour < 8);

  -- 1. Open a gap-episode when data goes stale and none is open.
  --    device_id IS NOT DISTINCT FROM = NULL-safe dedup (strap device_id is always NULL).
  FOR r IN
    SELECT c.user_id, c.device_id, c.minutes_since_last
    FROM v_ble_sync_cursor c
    LEFT JOIN ble_freshness_alerts a
      ON a.user_id = c.user_id
     AND a.device_id IS NOT DISTINCT FROM c.device_id
     AND a.state = 'open'
    WHERE c.minutes_since_last > p_threshold_min
      AND a.id IS NULL
  LOOP
    SELECT substring(value from 'reason=([^.]*)') INTO v_reason
    FROM bridge_logs
    WHERE user_id = r.user_id AND category = 'evt_ble_disconnected'
    ORDER BY created_at DESC LIMIT 1;

    INSERT INTO ble_freshness_alerts (user_id, device_id, minutes_since_last, state, disconnect_reason)
    VALUES (r.user_id, r.device_id, r.minutes_since_last, 'open', trim(v_reason))
    RETURNING id INTO v_id;

    INSERT INTO notification_queue (user_id, type, scheduled_for, title, body, priority)
    VALUES (
      r.user_id, 'cli', now(),
      CASE WHEN v_night THEN '🌙 Whoop stream dead — sleep is not being recorded'
           ELSE '📡 Whoop stream dead' END,
      'No biometric data for ' || round(r.minutes_since_last) || ' min.'
      || coalesce(E'\nLast disconnect: ' || trim(v_reason), '')
      || CASE WHEN v_night
              THEN E'\n\nEvery minute down is sleep data you do not get back. Reseat the strap and reopen LucidHealth.'
              ELSE E'\n\nReopen LucidHealth and check the strap is seated.' END,
      CASE WHEN v_night THEN 'high' ELSE 'normal' END
    );

    UPDATE ble_freshness_alerts SET notified_at = now() WHERE id = v_id;
  END LOOP;

  -- 2. Escalate once if an episode is STILL open 45+ min after the first ping.
  --    One extra banner per episode, never a per-minute drip.
  FOR r IN
    SELECT a.id, a.user_id, c.minutes_since_last
    FROM ble_freshness_alerts a
    JOIN v_ble_sync_cursor c
      ON c.user_id = a.user_id
     AND a.device_id IS NOT DISTINCT FROM c.device_id
    -- coalesce to detected_at so episodes opened by the old silent version
    -- (notified_at NULL) still escalate instead of sitting open forever.
    WHERE a.state = 'open'
      AND a.escalated_at IS NULL
      AND coalesce(a.notified_at, a.detected_at) < now() - interval '45 minutes'
      AND c.minutes_since_last > p_threshold_min
  LOOP
    INSERT INTO notification_queue (user_id, type, scheduled_for, title, body, priority)
    VALUES (
      r.user_id, 'cli', now(),
      '🚨 Whoop STILL down — ' || round(r.minutes_since_last) || ' min',
      'The stream never came back after the first alert. This needs the strap on the charger for a hard power-cycle.',
      'high'
    );
    UPDATE ble_freshness_alerts SET escalated_at = now() WHERE id = r.id;
  END LOOP;

  -- 3. Close the episode once the stream catches back up (<5 min). Stays silent —
  --    recovery does not need a banner, and a "back online" ping at 04:00 would
  --    wake him for nothing.
  UPDATE ble_freshness_alerts a
  SET state = 'recovered', recovered_at = NOW()
  FROM v_ble_sync_cursor c
  WHERE a.user_id = c.user_id
    AND a.device_id IS NOT DISTINCT FROM c.device_id
    AND a.state = 'open'
    AND c.minutes_since_last <= 5;
END $function$;
