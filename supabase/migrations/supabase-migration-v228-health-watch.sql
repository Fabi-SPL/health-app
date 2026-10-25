-- v228 - health_watch: the failures Fabi found himself, written down by the server so nobody has to notice them.
--
-- 10-25: a 19:00-22:12 couch block stood as the night, the app died at 01:34, most of the night sat on the
-- strap until the afternoon, and the phone kept saying "asleep" at 15:00. Each one was found by him reading
-- the app. This view lists those shapes for the last 3 days; a cron copies them into health_watch_log at
-- 11:30 Berlin so a morning read has history. Log only: no push, no nudge, nothing the app shows.
-- Rollback: supabase-migration-v228-rollback.sql

BEGIN;

CREATE OR REPLACE VIEW public.health_watch AS
  -- a night scored complete with under 4 h asleep
  SELECT 'night_short'::text kind, h.metric_date::timestamptz at,
         format('night %s scored complete with %s h asleep', h.metric_date, h.sleep_hours) detail
    FROM health_metrics h
   WHERE h.user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid
     AND h.metric_date >= (now() AT TIME ZONE 'Europe/Berlin')::date - 3
     AND h.night_data = 'complete' AND h.sleep_hours < 4
  UNION ALL
  -- a night silence that ended 2 h ago and is still mostly missing (strap history not uploaded)
  SELECT 'night_backfill_missing', o.started_at,
         format('%s min silent from %s, %s min came back, ended %s', o.minutes,
                to_char(o.started_at AT TIME ZONE 'Europe/Berlin', 'MM-DD HH24:MI'), coalesce(o.recovered_min, 0),
                to_char(o.ended_at AT TIME ZONE 'Europe/Berlin', 'MM-DD HH24:MI'))
    FROM strap_outages o
   WHERE o.user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid AND o.night
     AND o.started_at > now() - interval '3 days' AND o.ended_at < now() - interval '2 hours'
     AND o.minutes >= 30 AND coalesce(o.recovered_min, 0) < o.minutes * 0.8
  UNION ALL
  -- an alarm session still open 18 h after it was armed
  SELECT 'alarm_session_open', s.armed_at, format('session %s still %s', s.id, s.status)
    FROM smart_wake_sessions s
   WHERE s.user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid
     AND s.status NOT IN ('done', 'cancelled', 'fired', 'expired')
     AND s.armed_at < now() - interval '18 hours' AND s.armed_at > now() - interval '3 days'
  UNION ALL
  -- the phone still thinks he is asleep in the afternoon (it blocks the strap history download)
  SELECT 'phone_asleep_daytime', min(b.created_at), format('%s strap events with sleep=true between 13:00 and 20:00', count(*))
    FROM bridge_logs b
   WHERE b.user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid
     AND b.created_at > now() - interval '24 hours'
     AND b.key IN ('evt_ble_disconnected', 'history_drain_skipped')
     AND b.value LIKE '%sleep=true%'
     AND extract(hour FROM b.created_at AT TIME ZONE 'Europe/Berlin') BETWEEN 13 AND 19
  HAVING count(*) > 0
  UNION ALL
  SELECT 'cron_failed', max(d.start_time), format('%s failed %s times: %s', j.jobname, count(*), left(max(d.return_message), 160))
    FROM cron.job_run_details d JOIN cron.job j USING (jobid)
   WHERE d.start_time > now() - interval '24 hours' AND d.status = 'failed'
   GROUP BY j.jobname
  UNION ALL
  SELECT 'client_error', max(e.created_at), format('%s x %s: %s', count(*), e.area, left(max(e.message), 160))
    FROM client_error_log e
   WHERE e.created_at > now() - interval '24 hours'
   GROUP BY e.area;

REVOKE ALL ON public.health_watch FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.health_watch_log (
  id bigserial PRIMARY KEY,
  logged_at timestamptz NOT NULL DEFAULT now(),
  kind text NOT NULL,
  at timestamptz,
  detail text
);
ALTER TABLE public.health_watch_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.health_watch_log FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('health-watch', '30 10 * * *',
  $$INSERT INTO public.health_watch_log (kind, at, detail) SELECT kind, at, detail FROM public.health_watch$$);

COMMIT;
