-- migration v124_alarm_circadian_wire.sql
-- Wire circadian_phase (v122) into the smart-alarm wake planner.
--
-- BUG: when there is no calendar event, plan_tonight_from_calendar defaulted the
-- wake to estimate_circadian_anchor.optimal_wake_hour = HR-nadir + 2 = ~05-06:00.
-- Wrong for Fabi's LATE chronotype (real natural wake ~08:30). The materialized
-- smart_alarm_plan was storing a 06:00 wake → an early force-wake that wrecks him.
--
-- FIX (2 functions, applied live):
--   * plan_tonight_from_calendar: no-event default wake now reads
--     circadian_phase(user).natural_wake_hour (8.5 = 08:30), not nadir+2.
--   * plan_tonight: the circadian grogginess warning now references the real
--     natural wake (~08:30) instead of cbtmin+2 (~05:00), so it warns correctly
--     when a calendar deadline forces a wake before his natural rise.
-- Validated: plan_tonight_auto target_wake 06:00 -> 08:30; refresh_tonight_plan
-- stores 08:30; no warning at 08:30; calendar-deadline path unchanged.
-- App reads the materialized smart_alarm_plan, so the wake window updates on the
-- next sync with NO app build (server-side only).

CREATE OR REPLACE FUNCTION public.plan_tonight(p_user_id uuid, p_wake_deadline timestamptz, p_prep_min integer DEFAULT 45, p_travel_min integer DEFAULT 0, p_winddown_min integer DEFAULT 45)
RETURNS TABLE(winddown_start timestamptz, target_bedtime timestamptz, target_wake timestamptz, wake_window_start timestamptz, wake_window_end timestamptz, target_sleep_h numeric, sleep_opportunity_min integer, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE w_latest timestamptz; nstar numeric; lat int; tw timestamptz; bed timestamptz; wd timestamptz;
  ow numeric; wake_hr numeric; parts text; opp int; now_b timestamptz := now();
BEGIN
  w_latest := p_wake_deadline - make_interval(mins => (p_prep_min + p_travel_min));
  SELECT t.target_h INTO nstar FROM target_sleep_duration(p_user_id) t; nstar := COALESCE(nstar, 8.0);
  SELECT mu INTO lat FROM personal_priors WHERE user_id=p_user_id AND param='sleep_latency_min'; lat := COALESCE(lat, 18);
  tw := w_latest;
  bed := tw - make_interval(mins => lat) - make_interval(secs => round(nstar*3600)::int);
  wd := bed - make_interval(mins => p_winddown_min);
  target_wake := tw; wake_window_end := tw; wake_window_start := tw - interval '20 minutes';
  target_bedtime := bed; winddown_start := wd; target_sleep_h := nstar;
  opp := round(EXTRACT(epoch FROM (tw - bed))/60.0)::int - lat; sleep_opportunity_min := opp;
  -- circadian sanity now uses his REAL natural wake (~08:30), not nadir+2
  SELECT (circadian_phase(p_user_id)->>'natural_wake_hour')::numeric INTO ow; ow := COALESCE(ow, 8.5);
  wake_hr := extract(hour FROM tw AT TIME ZONE 'Europe/Berlin') + extract(minute FROM tw AT TIME ZONE 'Europe/Berlin')/60.0;
  parts := format('Lights out by %s, wind down from %s. Sleep ~%sh.', to_char(bed AT TIME ZONE 'Europe/Berlin','HH24:MI'), to_char(wd AT TIME ZONE 'Europe/Berlin','HH24:MI'), nstar);
  IF wake_hr < ow - 0.5 THEN
    parts := parts || format(' (!) that wake (%s) is before your natural rise (~%s), expect some grogginess.', to_char(tw AT TIME ZONE 'Europe/Berlin','HH24:MI'), to_char(make_interval(mins => round(ow*60)::int),'HH24:MI'));
  END IF;
  IF bed <= now_b THEN parts := parts || ' You are already past the ideal bedtime, head to bed as soon as you can.';
  ELSIF wd <= now_b THEN parts := parts || ' Start winding down now.'; END IF;
  note := parts; RETURN NEXT;
END;$function$;

CREATE OR REPLACE FUNCTION public.plan_tonight_from_calendar(p_user_id uuid, p_prep_min integer DEFAULT 45, p_travel_min integer DEFAULT 0, p_winddown_min integer DEFAULT 45)
RETURNS TABLE(winddown_start timestamptz, target_bedtime timestamptz, target_wake timestamptz, wake_window_start timestamptz, wake_window_end timestamptz, target_sleep_h numeric, sleep_opportunity_min integer, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE deadline timestamptz; tom date := (now() AT TIME ZONE 'Europe/Berlin')::date + 1; nw numeric;
BEGIN
  SELECT min((date::timestamp + start_time::time) AT TIME ZONE 'Europe/Berlin') INTO deadline
  FROM events WHERE user_id=p_user_id AND date = tom AND COALESCE(all_day,false) = false AND start_time IS NOT NULL;
  IF deadline IS NULL THEN
    -- no event: default to his real circadian natural wake (~08:30), NOT the old
    -- estimate_circadian_anchor optimal_wake (nadir+2 = ~05-06, wrong chronotype).
    SELECT (circadian_phase(p_user_id)->>'natural_wake_hour')::numeric INTO nw; nw := COALESCE(nw, 8.5);
    deadline := ((tom::timestamp) + make_interval(mins => round(nw*60)::int)) AT TIME ZONE 'Europe/Berlin' + make_interval(mins => p_prep_min + p_travel_min);
  END IF;
  RETURN QUERY SELECT * FROM plan_tonight(p_user_id, deadline, p_prep_min, p_travel_min, p_winddown_min);
END;$function$;
