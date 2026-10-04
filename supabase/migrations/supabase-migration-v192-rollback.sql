-- v192 rollback: drops the auth.uid() overload; sleep_duration_baseline(uuid, integer) was never changed
DROP FUNCTION IF EXISTS public.sleep_duration_baseline(integer);

NOTIFY pgrst, 'reload schema';
