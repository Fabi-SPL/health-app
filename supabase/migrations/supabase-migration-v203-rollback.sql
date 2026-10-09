-- v203 rollback: stop deriving waveform heart rate. Raw records and derived rows are kept.
SELECT cron.unschedule('derive_hr_from_hist_raw') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'derive_hr_from_hist_raw');
DROP FUNCTION IF EXISTS public.derive_hr_from_hist_raw(uuid, integer);
-- recompute_backfilled_nights: re-run supabase-migration-v200-recompute-backfilled-nights.sql to restore the old source list.
