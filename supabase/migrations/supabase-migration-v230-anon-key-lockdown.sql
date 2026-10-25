-- v230 - The public anon key stops reading his health data.
--
-- The anon key ships inside the LucidRide app, whose repo (ride-app) is public, so anyone holding it could read
-- through ten policies that matched his user id instead of the signed-in user. Proved 2026-10-25 with that key:
-- realtime_health 4.0 M rows, ride_telemetry 194 k, activities 2.4 k, biostate_history 13.6 k, plus blood
-- pressure, body composition and state_truth_log. LucidHealth reads all of these with his signed-in token, which
-- the owner policies (uid() = user_id) already cover. The only anon reader is LucidRide, unused since 2026-09-17;
-- it needs password sign-in (like LucidHealth) before its history screens work again. Its anon INSERT policies
-- stay, so a ride still records.
-- Also: the two tracker views ran as their owner and were fully open to anon; four health RPCs were executable
-- by anon; the family page's 4-digit PIN had no limit on wrong guesses.
-- Rollback: supabase-migration-v230-rollback.sql

BEGIN;

DROP POLICY lucidride_anon_read_rh ON public.realtime_health;
DROP POLICY lucidride_anon_read_act ON public.activities;
DROP POLICY lucidride_anon_upd_act ON public.activities;
DROP POLICY lucidride_anon_read_telemetry ON public.ride_telemetry;
DROP POLICY bsc_anon_read ON public.biostate_config;
DROP POLICY bsh_anon_read ON public.biostate_history;
DROP POLICY bss_anon_read ON public.biostate_state;
DROP POLICY bp_anon_read ON public.blood_pressure_readings;
DROP POLICY stl_anon_read ON public.state_truth_log;
DROP POLICY bcl_owner ON public.body_composition_log;
CREATE POLICY bcl_own ON public.body_composition_log FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- ride_telemetry had no signed-in policy at all; this one is what LucidRide reads through once it signs in.
CREATE POLICY rt_own ON public.ride_telemetry FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

REVOKE ALL ON public.ride_tracker_summary, public.tracker_sessions FROM anon;

REVOKE EXECUTE ON FUNCTION public.minutes_with_realtime_data(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.minutes_with_realtime_data_packed(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.pc_daily_summary(uuid, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.recompute_health_metrics(uuid, date) FROM PUBLIC, anon;

CREATE SEQUENCE IF NOT EXISTS public.family_pin_fail_seq;
REVOKE ALL ON SEQUENCE public.family_pin_fail_seq FROM PUBLIC, anon, authenticated;
INSERT INTO public.family_config (key, value, updated_at) VALUES ('pin_fail_mark', '0', now()) ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_family_view_data(p_pin text, p_start_date text, p_end_date text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  stored_pin text;
  fails bigint;
  target_user_id uuid;
BEGIN
  SELECT value INTO stored_pin FROM family_config WHERE key = 'pin';
  -- v230: a 4-digit PIN behind the public anon key fell to 10,000 tries. Ten wrong PINs a day, then nothing
  -- until the 03:00 reset. A sequence counts them because nextval survives the exception's rollback.
  SELECT (CASE WHEN s.is_called THEN s.last_value ELSE 0 END) - COALESCE((SELECT value::bigint FROM family_config WHERE key = 'pin_fail_mark'), 0)
    INTO fails FROM family_pin_fail_seq s;
  IF fails >= 10 THEN
    RAISE EXCEPTION 'Too many wrong PINs today';
  END IF;
  IF stored_pin IS NULL OR p_pin IS DISTINCT FROM stored_pin THEN
    PERFORM nextval('family_pin_fail_seq');
    RAISE EXCEPTION 'Invalid PIN';
  END IF;

  SELECT id INTO target_user_id FROM auth.users ORDER BY created_at LIMIT 1;
  IF target_user_id IS NULL THEN
    RAISE EXCEPTION 'No user found';
  END IF;

  RETURN json_build_object(
    'tasks', (
      SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.completed_at DESC), '[]'::json)
      FROM (
        -- (1) Real completed tasks
        SELECT
          id, title, project, sub_project, priority, time_estimate_minutes, completed_at
        FROM tasks
        WHERE user_id = target_user_id
          AND status = 'completed'
          AND completed_at IS NOT NULL
          AND (completed_at AT TIME ZONE 'Europe/Berlin')::date >= p_start_date::date
          AND (completed_at AT TIME ZONE 'Europe/Berlin')::date <= p_end_date::date

        UNION ALL

        -- (2) Ghost threads (no linked thread_tasks)
        SELECT
          th.id, th.title, th.project, th.sub_project, 'medium'::text AS priority,
          NULL::int AS time_estimate_minutes, th.updated_at AS completed_at
        FROM threads th
        WHERE th.user_id = target_user_id
          AND th.status = 'completed'
          AND th.updated_at IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM thread_tasks tt WHERE tt.thread_id = th.id)
          AND (th.updated_at AT TIME ZONE 'Europe/Berlin')::date >= p_start_date::date
          AND (th.updated_at AT TIME ZONE 'Europe/Berlin')::date <= p_end_date::date

        UNION ALL

        -- (3) Session-saves and research reports (knowledge_entries)
        SELECT
          ke.id,
          ke.title,
          ke.project,
          NULL::text AS sub_project,
          'medium'::text AS priority,
          NULL::int AS time_estimate_minutes,
          ke.created_at AS completed_at
        FROM knowledge_entries ke
        WHERE ke.user_id = target_user_id
          AND (
            ke.source_type = 'report'
            OR (
              ke.source_type = 'code_session'
              AND ke.title ILIKE 'Session:%'
              AND ke.title NOT ILIKE 'Session Index:%'
            )
          )
          AND (ke.created_at AT TIME ZONE 'Europe/Berlin')::date >= p_start_date::date
          AND (ke.created_at AT TIME ZONE 'Europe/Berlin')::date <= p_end_date::date
      ) t
    ),
    'all_completion_dates', (
      SELECT COALESCE(json_agg(DISTINCT d), '[]'::json)
      FROM (
        SELECT ((completed_at AT TIME ZONE 'Europe/Berlin')::date)::text AS d
        FROM tasks
        WHERE user_id = target_user_id AND status = 'completed' AND completed_at IS NOT NULL

        UNION

        SELECT ((updated_at AT TIME ZONE 'Europe/Berlin')::date)::text AS d
        FROM threads th
        WHERE th.user_id = target_user_id
          AND th.status = 'completed'
          AND th.updated_at IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM thread_tasks tt WHERE tt.thread_id = th.id)

        UNION

        SELECT ((ke.created_at AT TIME ZONE 'Europe/Berlin')::date)::text AS d
        FROM knowledge_entries ke
        WHERE ke.user_id = target_user_id
          AND (
            ke.source_type = 'report'
            OR (
              ke.source_type = 'code_session'
              AND ke.title ILIKE 'Session:%'
              AND ke.title NOT ILIKE 'Session Index:%'
            )
          )
      ) dates
    )
  );
END;
$function$;

SELECT cron.schedule('family-pin-fail-reset', '0 3 * * *',
  $$UPDATE public.family_config SET value = (SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM public.family_pin_fail_seq)::text, updated_at = now() WHERE key = 'pin_fail_mark'$$);

COMMIT;
