-- v192: the app calls sleep_duration_baseline with only {"p_days": 30} (SupabaseClient.fetchSleepDurationBaseline),
-- but the live function needs p_user_id, so PostgREST answered 404 PGRST202 on every call: 1,039 device_log lines 09-15..10-02.
-- Server-side fix, no app build: an auth.uid() overload that delegates to the (uuid, integer) function, which stays untouched.
-- Not ambiguous: PostgREST matches on argument names and the (uuid, integer) one has no default for p_user_id; no SQL caller exists.
-- Rollback: supabase-migration-v192-rollback.sql (drops this overload only).

CREATE OR REPLACE FUNCTION public.sleep_duration_baseline(p_days integer DEFAULT 30)
 RETURNS TABLE(mean_hours numeric, sd_hours numeric, n_nights integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  SELECT * FROM public.sleep_duration_baseline(auth.uid(), p_days);
$function$;

REVOKE ALL ON FUNCTION public.sleep_duration_baseline(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sleep_duration_baseline(integer) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
