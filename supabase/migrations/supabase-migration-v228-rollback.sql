-- v228 rollback - removes the health_watch view, its log table and the cron job.
BEGIN;
SELECT cron.unschedule('health-watch');
DROP VIEW IF EXISTS public.health_watch;
DROP TABLE IF EXISTS public.health_watch_log;
COMMIT;
