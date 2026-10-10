-- v195 rollback: hands the load columns back to the app
DROP TRIGGER IF EXISTS trg_guard_server_load_columns ON public.health_metrics;
DROP FUNCTION IF EXISTS public.guard_server_load_columns();
SELECT cron.unschedule('load_metrics_15min');
SELECT cron.unschedule('load_metrics_finalize');
DROP FUNCTION IF EXISTS public.compute_load_metrics(uuid, date);
