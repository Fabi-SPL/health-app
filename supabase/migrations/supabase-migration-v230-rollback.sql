-- v230 rollback - reopens the anon policies, grants and the unthrottled family PIN exactly as they were before v230.

BEGIN;

DROP POLICY IF EXISTS bcl_own ON public.body_composition_log;
DROP POLICY IF EXISTS rt_own ON public.ride_telemetry;
CREATE POLICY lucidride_anon_read_rh ON public.realtime_health AS PERMISSIVE FOR SELECT TO anon USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY lucidride_anon_read_act ON public.activities AS PERMISSIVE FOR SELECT TO anon USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY lucidride_anon_upd_act ON public.activities AS PERMISSIVE FOR UPDATE TO anon USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)) WITH CHECK ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY lucidride_anon_read_telemetry ON public.ride_telemetry AS PERMISSIVE FOR SELECT TO anon USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY bsc_anon_read ON public.biostate_config AS PERMISSIVE FOR SELECT TO public USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY stl_anon_read ON public.state_truth_log AS PERMISSIVE FOR SELECT TO public USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY bss_anon_read ON public.biostate_state AS PERMISSIVE FOR SELECT TO public USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY bsh_anon_read ON public.biostate_history AS PERMISSIVE FOR SELECT TO public USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY bp_anon_read ON public.blood_pressure_readings AS PERMISSIVE FOR SELECT TO public USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));
CREATE POLICY bcl_owner ON public.body_composition_log AS PERMISSIVE FOR ALL TO public USING ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)) WITH CHECK ((user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid));

GRANT ALL ON public.ride_tracker_summary, public.tracker_sessions TO anon;

GRANT EXECUTE ON FUNCTION public.minutes_with_realtime_data(uuid, timestamptz, timestamptz) TO PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.minutes_with_realtime_data_packed(uuid, timestamptz, timestamptz) TO PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pc_daily_summary(uuid, date) TO PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recompute_health_metrics(uuid, date) TO PUBLIC, anon;

SELECT cron.unschedule('family-pin-fail-reset');

CREATE OR REPLACE FUNCTION public.get_family_view_data(p_pin text, p_start_date text, p_end_date text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  stored_pin text;
  target_user_id uuid;
BEGIN
  SELECT value INTO stored_pin FROM family_config WHERE key = 'pin';
  IF stored_pin IS NULL OR p_pin != stored_pin THEN
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

DELETE FROM public.family_config WHERE key = 'pin_fail_mark';
DROP SEQUENCE IF EXISTS public.family_pin_fail_seq;

COMMIT;
