-- v173 — notification_queue had no consumer.
--
-- Health has two notification systems. `nudges` is the live one: the Bridge
-- iOS app polls it every 30s and fires a native banner. `notification_queue` is
-- written by ble_freshness_check() and friends, and nothing has ever read it —
-- 870 rows queued, 29 ever stamped sent_at, the last one on 2026-03-30.
--
-- That is why the Whoop went dark on 2026-08-17 at 18:12 and nobody was told:
-- two "Whoop stream dead" alerts fired correctly at 19:20 and 20:06 into a table
-- with no reader, and the outage ran for three days.
--
-- Fix is a drain rather than a rewrite of every writer: one job moves fresh rows
-- into `nudges` and stamps sent_at. Any future writer of notification_queue is
-- covered automatically, and no working logic is touched.

CREATE OR REPLACE FUNCTION public.drain_notification_queue(p_max_age_min integer DEFAULT 120)
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_moved int := 0;
BEGIN
  WITH due AS (
    SELECT id, user_id, title, body, priority
    FROM notification_queue
    WHERE sent_at IS NULL
      AND skipped IS NOT TRUE
      AND dismissed_at IS NULL
      AND scheduled_for <= now()
      AND scheduled_for > now() - make_interval(mins => p_max_age_min)
      AND (snoozed_until IS NULL OR snoozed_until <= now())
      AND (expires_at IS NULL OR expires_at > now())
    ORDER BY scheduled_for
    LIMIT 20
  ), ins AS (
    INSERT INTO nudges (user_id, title, message, priority, channels, status, source, metadata)
    SELECT d.user_id,
           d.title,
           d.body,
           CASE WHEN d.priority = 'high' THEN 'voice' ELSE 'visual' END,
           ARRAY['push'],
           'pending',
           'cron',   -- nudges_source_check only allows companion|cron|health|cli|system|user
           jsonb_build_object('notification_queue_id', d.id)
    FROM due d
    RETURNING (metadata->>'notification_queue_id')::uuid AS qid
  )
  UPDATE notification_queue q
  SET sent_at = now()
  FROM ins
  WHERE q.id = ins.qid;

  GET DIAGNOSTICS v_moved = ROW_COUNT;
  RETURN v_moved;
END $function$;

-- Stale rows are worse than no rows: a "your streak is at risk" banner from three
-- weeks ago is noise. Everything older than the drain window gets closed out, with
-- the reason recorded so the history stays honest.
UPDATE notification_queue
SET skipped = true,
    skip_reason = 'stale backlog — notification_queue had no consumer until v173; delivered late is worse than not delivered'
WHERE sent_at IS NULL
  AND skipped IS NOT TRUE
  AND scheduled_for < now() - interval '2 hours';

SELECT cron.unschedule('notification_queue_drain')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'notification_queue_drain');

SELECT cron.schedule('notification_queue_drain', '*/2 * * * *',
                     $$SELECT public.drain_notification_queue(120)$$);
