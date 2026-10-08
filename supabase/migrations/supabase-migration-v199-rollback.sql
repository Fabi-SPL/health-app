-- v199 rollback: removes the strap outage log.
SELECT cron.unschedule('strap_outages_5min');
DROP FUNCTION IF EXISTS public.strap_outage_latest(uuid, integer);
DROP FUNCTION IF EXISTS public.refresh_strap_outages(uuid, timestamptz);
DROP FUNCTION IF EXISTS public.classify_strap_gap(uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.app_heartbeats(uuid, timestamptz, timestamptz);
DROP TABLE IF EXISTS public.strap_outages;
DROP INDEX IF EXISTS public.idx_knowledge_entries_device_log_time;
DROP FUNCTION IF EXISTS public.minutes_with_realtime_data_packed(uuid, timestamptz, timestamptz);

-- restore the pre-v199 ble_freshness_check (night alerts voice)
CREATE OR REPLACE FUNCTION public.ble_freshness_check(p_threshold_min integer DEFAULT 10)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r record;
  v_reason text;
  v_hour int;
  v_night boolean;
  v_notify_after int;
  v_sent_today int;
  v_cap constant int := 3;
  v_qid uuid;
BEGIN
  v_hour  := extract(hour FROM (now() AT TIME ZONE 'Europe/Berlin'));
  v_night := (v_hour >= 22 OR v_hour < 8);
  v_notify_after := CASE WHEN v_night THEN 12 ELSE 30 END;

  -- 1. Open a gap-episode when data goes stale. SILENT on purpose now — an
  --    episode opening is a fact worth recording, not yet worth interrupting.
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
    VALUES (r.user_id, r.device_id, r.minutes_since_last, 'open', trim(v_reason));
  END LOOP;

  -- 2. Notify only once an episode has SURVIVED the notify window. A gap that
  --    heals itself inside that window is never mentioned.
  FOR r IN
    SELECT a.id, a.user_id, a.disconnect_reason, c.minutes_since_last
    FROM ble_freshness_alerts a
    JOIN v_ble_sync_cursor c
      ON c.user_id = a.user_id
     AND a.device_id IS NOT DISTINCT FROM c.device_id
    WHERE a.state = 'open'
      AND a.notified_at IS NULL
      AND a.detected_at < now() - make_interval(mins => v_notify_after)
      AND c.minutes_since_last > p_threshold_min
  LOOP
    SELECT count(*) INTO v_sent_today
      FROM notification_queue
     WHERE user_id = r.user_id
       AND title LIKE '%Whoop%'
       AND scheduled_for >= date_trunc('day', now() AT TIME ZONE 'Europe/Berlin') AT TIME ZONE 'Europe/Berlin';

    IF v_sent_today >= v_cap THEN
      -- mark it handled anyway so it does not queue up behind the cap
      UPDATE ble_freshness_alerts SET notified_at = now() WHERE id = r.id;
      CONTINUE;
    END IF;

    INSERT INTO notification_queue (user_id, type, scheduled_for, title, body, priority)
    VALUES (
      r.user_id, 'cli', now(),
      CASE WHEN v_night THEN '🌙 Whoop stream dead — sleep is not being recorded'
           ELSE '📡 Whoop stream dead' END,
      'No biometric data for ' || round(r.minutes_since_last) || ' min.'
      || coalesce(E'\nLast disconnect: ' || r.disconnect_reason, '')
      || CASE WHEN v_night
              THEN E'\n\nEvery minute down is sleep data you do not get back. Reseat the strap and reopen LucidHealth.'
              ELSE E'\n\nReopen LucidHealth and check the strap is seated.' END,
      CASE WHEN v_night THEN 'high' ELSE 'normal' END
    ) RETURNING id INTO v_qid;

    -- 2026-09-11: notification_queue alone never reached the phone. 311 'cli' rows
    -- in 14 days, 0 delivered — including every alert for the 40h outage that ate
    -- the night of 09-10. The phone polls nudges, so write there too, same id so
    -- drain_notification_queue's guard can't double-fire it.
    INSERT INTO nudges (id, user_id, title, message, deliver_at, priority, channels, status, source, metadata)
    SELECT q.id, q.user_id, q.title, q.body, now(),
           CASE WHEN q.priority = 'high' THEN 'voice' ELSE 'visual' END,
           ARRAY['push'], 'pending', 'health',
           jsonb_build_object('kind','ble_stream_dead','minutes_down',round(r.minutes_since_last))
    FROM notification_queue q WHERE q.id = v_qid;

    UPDATE ble_freshness_alerts SET notified_at = now() WHERE id = r.id;
  END LOOP;

  -- 3. One escalation if it is STILL dead 45 min after the first banner.
  FOR r IN
    SELECT a.id, a.user_id, c.minutes_since_last
    FROM ble_freshness_alerts a
    JOIN v_ble_sync_cursor c
      ON c.user_id = a.user_id
     AND a.device_id IS NOT DISTINCT FROM c.device_id
    WHERE a.state = 'open'
      AND a.notified_at IS NOT NULL
      AND a.escalated_at IS NULL
      AND a.notified_at < now() - interval '45 minutes'
      AND c.minutes_since_last > p_threshold_min
  LOOP
    INSERT INTO notification_queue (user_id, type, scheduled_for, title, body, priority)
    VALUES (
      r.user_id, 'cli', now(),
      '🚨 Whoop STILL down — ' || round(r.minutes_since_last) || ' min',
      'The stream never came back after the first alert. This needs the strap on the charger for a hard power-cycle.',
      'high'
    ) RETURNING id INTO v_qid;

    INSERT INTO nudges (id, user_id, title, message, deliver_at, priority, channels, status, source, metadata)
    SELECT q.id, q.user_id, q.title, q.body, now(), 'voice',
           ARRAY['push'], 'pending', 'health',
           jsonb_build_object('kind','ble_stream_dead_escalation','minutes_down',round(r.minutes_since_last))
    FROM notification_queue q WHERE q.id = v_qid;

    UPDATE ble_freshness_alerts SET escalated_at = now() WHERE id = r.id;
  END LOOP;

  -- 4. Silent recovery close.
  UPDATE ble_freshness_alerts a
  SET state = 'recovered', recovered_at = NOW()
  FROM v_ble_sync_cursor c
  WHERE a.user_id = c.user_id
    AND a.device_id IS NOT DISTINCT FROM c.device_id
    AND a.state = 'open'
    AND c.minutes_since_last <= 5;
END $function$
;
