-- v229 - Pin search_path on 13 SECURITY DEFINER functions, and lock the v227 backup table.
--
-- Server audit 2026-10-25: these definer functions run with the owner's rights and had no fixed search_path,
-- so a caller who can create objects earlier on the path could hijack a name they call. The v227 backup copy
-- of health_metrics had RLS off and was readable by the authenticated role.
-- Rollback: supabase-migration-v229-rollback.sql

BEGIN;

ALTER FUNCTION public.compute_food_correlations(uuid,integer) SET search_path = public, pg_temp;
ALTER FUNCTION public.detect_regime_changes(uuid,text,integer) SET search_path = public, pg_temp;
ALTER FUNCTION public.get_injectable_preferences(real,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.hub_dismiss(uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.hub_dismiss_sync() SET search_path = public, pg_temp;
ALTER FUNCTION public.hub_fanout() SET search_path = public, pg_temp;
ALTER FUNCTION public.hub_snooze(uuid,integer) SET search_path = public, pg_temp;
ALTER FUNCTION public.n1_ab_randomization_test(uuid,text,date,date,date,integer) SET search_path = public, pg_temp;
ALTER FUNCTION public.n1_within_person_assoc(uuid,text,integer,integer) SET search_path = public, pg_temp;
ALTER FUNCTION public.regime_detect_nightly() SET search_path = public, pg_temp;
ALTER FUNCTION public.rescore_importance_from_recall(uuid,integer) SET search_path = public, pg_temp;
ALTER FUNCTION public.set_user_preference(text,text,text,real,uuid) SET search_path = public, pg_temp;
ALTER FUNCTION public.supersede_thread_atoms(text,text,uuid) SET search_path = public, pg_temp;

REVOKE ALL ON public.health_metrics_v227_before FROM PUBLIC, anon, authenticated;
ALTER TABLE public.health_metrics_v227_before ENABLE ROW LEVEL SECURITY;

COMMIT;
