SELECT cron.unschedule('recompute_backfilled_nights');
DROP FUNCTION IF EXISTS public.recompute_backfilled_nights(uuid, integer);
DROP TABLE IF EXISTS public.night_backfill_marks;
