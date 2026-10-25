-- v229 rollback
BEGIN;
ALTER FUNCTION public.compute_food_correlations(uuid,integer) RESET search_path;
ALTER FUNCTION public.detect_regime_changes(uuid,text,integer) RESET search_path;
ALTER FUNCTION public.get_injectable_preferences(real,uuid) RESET search_path;
ALTER FUNCTION public.hub_dismiss(uuid) RESET search_path;
ALTER FUNCTION public.hub_dismiss_sync() RESET search_path;
ALTER FUNCTION public.hub_fanout() RESET search_path;
ALTER FUNCTION public.hub_snooze(uuid,integer) RESET search_path;
ALTER FUNCTION public.n1_ab_randomization_test(uuid,text,date,date,date,integer) RESET search_path;
ALTER FUNCTION public.n1_within_person_assoc(uuid,text,integer,integer) RESET search_path;
ALTER FUNCTION public.regime_detect_nightly() RESET search_path;
ALTER FUNCTION public.rescore_importance_from_recall(uuid,integer) RESET search_path;
ALTER FUNCTION public.set_user_preference(text,text,text,real,uuid) RESET search_path;
ALTER FUNCTION public.supersede_thread_atoms(text,text,uuid) RESET search_path;
ALTER TABLE public.health_metrics_v227_before DISABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.health_metrics_v227_before TO authenticated;
COMMIT;
