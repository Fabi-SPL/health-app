-- v199 rollback: removes the strap outage log.
SELECT cron.unschedule('strap_outages_5min');
DROP FUNCTION IF EXISTS public.strap_outage_latest(uuid, integer);
DROP FUNCTION IF EXISTS public.refresh_strap_outages(uuid, timestamptz);
DROP FUNCTION IF EXISTS public.classify_strap_gap(uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.app_heartbeats(uuid, timestamptz, timestamptz);
DROP TABLE IF EXISTS public.strap_outages;
DROP INDEX IF EXISTS public.idx_knowledge_entries_device_log_time;
DROP FUNCTION IF EXISTS public.minutes_with_realtime_data_packed(uuid, timestamptz, timestamptz);
