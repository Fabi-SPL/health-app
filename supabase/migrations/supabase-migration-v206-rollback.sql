-- v206 rollback: removes the evening low-battery push.
SELECT cron.unschedule('strap_low_battery_evening') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'strap_low_battery_evening');
DROP FUNCTION IF EXISTS public.strap_low_battery_check(uuid, boolean);
