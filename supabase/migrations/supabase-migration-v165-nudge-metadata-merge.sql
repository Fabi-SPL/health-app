-- v165 — stop the iOS delivery ack from destroying nudge metadata.
--
-- markNudgeDelivered PATCHed  {"metadata": {"ios_delivered_at": ...}}  which
-- REPLACES the whole jsonb. That wiped metadata->>'kind' and 'session_id':
--   * hangry_guardrail_check dedups on metadata->>'kind' = 'hangry_prewarning',
--     so once the key was gone the dedup stopped matching and the nudge re-fired.
--     Verified: "short fuse today" sent 4x on 2026-08-06 (13/15/17/19 UTC)
--     and 2x on 2026-07-28.
--   * NotificationListener uses kind='smart_wake' to escalate to the strap
--     buzzer, so a wiped row silently lost its escalation.
--
-- This RPC merges instead of replacing. The client calls it rather than PATCHing
-- the column directly. security invoker keeps the "Users see own nudges" RLS
-- policy in force, so a caller can still only ack their own rows.

create or replace function public.mark_nudge_delivered(
  p_nudge_id uuid,
  p_delivered_at timestamptz default now()
) returns void
language sql
security invoker
as $$
  update public.nudges
     set metadata = coalesce(metadata, '{}'::jsonb)
                    || jsonb_build_object('ios_delivered_at', p_delivered_at)
   where id = p_nudge_id;
$$;

grant execute on function public.mark_nudge_delivered(uuid, timestamptz) to authenticated;
