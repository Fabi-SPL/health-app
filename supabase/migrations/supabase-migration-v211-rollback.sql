-- v211 rollback: every nudge with 'push' reaches the health app again; meal detection back on.
DROP TRIGGER IF EXISTS trg_nudge_push_gate ON public.nudges;
DROP FUNCTION IF EXISTS public.nudge_push_gate();
DROP FUNCTION IF EXISTS public.nudge_push_category(text, text, jsonb);
DROP TABLE IF EXISTS public.health_push_policy;
SELECT cron.alter_job(jobid, active := true) FROM cron.job WHERE jobname = 'meal_detect_experiment';
