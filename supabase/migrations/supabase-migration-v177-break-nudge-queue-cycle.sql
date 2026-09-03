-- v177 — break the drain <-> fanout cycle introduced by v173
--
-- v173 added drain_notification_queue(): notification_queue -> nudges.
-- hub_fanout() already mirrored the other way: nudges -> notification_queue.
-- Together they formed a closed loop. Every 2 minutes the drain re-emitted
-- every message it had already delivered, under a fresh id, forever.
-- Evidence: one CLI test message at 16:16 became 216 nudges by 23:26.
--
-- The cycle closes at the fanout, so the guard belongs there: a nudge that
-- was created FROM a queue row must not be mirrored back INTO the queue.
-- Every other nudge writer still fans out to the tablet unchanged.

CREATE OR REPLACE FUNCTION public.hub_fanout()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
begin
  -- Came from drain_notification_queue() — mirroring it back would loop.
  if new.metadata ? 'notification_queue_id' then
    return new;
  end if;

  -- Mirror to the tablet feed when the nudge is meant to reach Fabi
  -- (push OR an explicit tablet channel), unless suppressed.
  if (new.channels && array['push','nightstand','tablet']::text[])
     and coalesce(new.metadata->>'no_tablet', '') <> 'true' then
    insert into public.notification_queue
      (id, user_id, type, title, body, briefing, priority, context_data,
       expires_at, scheduled_for, created_at, skipped, sent_at, ai_generated)
    values
      (new.id, new.user_id,
       coalesce(new.metadata->>'type', new.source, 'hub'),
       coalesce(new.title, 'Lucid'),
       coalesce(new.message, ''),
       new.metadata->>'briefing',
       new.priority,
       new.metadata,
       coalesce((new.metadata->>'expires_at')::timestamptz,
                coalesce(new.deliver_at, now()) + interval '24 hours'),
       coalesce(new.deliver_at, now()),
       now(), false, null, true)
    on conflict (id) do nothing;
  end if;
  return new;
end;
$function$;

-- Belt and braces: the drain also refuses anything the fanout produced,
-- so a future writer re-opening the cycle from the other side cannot loop.
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
      AND NOT (context_data ? 'notification_queue_id')   -- fanout echo
      AND NOT EXISTS (SELECT 1 FROM nudges n WHERE n.id = notification_queue.id)
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
           'cron',
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
