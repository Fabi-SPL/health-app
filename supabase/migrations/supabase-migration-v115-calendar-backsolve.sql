-- migration v115_calendar_backsolve.sql
-- Smart Alarm — Module 6: the calendar backsolve (the capstone).
--
-- Source: deep-research 2026-06-04 (kb 3599a20f), Domain 6. Given tomorrow's
-- hard commitment, it computes the whole night backwards: latest-safe wake →
-- wake window → bedtime → wind-down start. Pulls his personal sleep need from
-- Module 4 and warns (via Module 5) if the forced wake lands before his natural
-- rise. This is the "10am meeting sets your night" feature.
--
-- plan_tonight(user, wake_deadline, prep_min, travel_min, winddown_min)
-- plan_tonight_from_calendar(user) — finds tomorrow's first event and plans.

CREATE OR REPLACE FUNCTION public.plan_tonight(
  p_user_id uuid,
  p_wake_deadline timestamptz,
  p_prep_min int DEFAULT 45,
  p_travel_min int DEFAULT 0,
  p_winddown_min int DEFAULT 45
)
RETURNS TABLE(
  winddown_start timestamptz, target_bedtime timestamptz, target_wake timestamptz,
  wake_window_start timestamptz, wake_window_end timestamptz,
  target_sleep_h numeric, sleep_opportunity_min int, note text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE
  w_latest timestamptz; nstar numeric; lat int; tw timestamptz; bed timestamptz; wd timestamptz;
  ow numeric; cbt numeric; wake_hr numeric; parts text; opp int; now_b timestamptz := now();
BEGIN
  w_latest := p_wake_deadline - make_interval(mins => (p_prep_min + p_travel_min));

  SELECT t.target_h INTO nstar FROM target_sleep_duration(p_user_id) t;
  nstar := COALESCE(nstar, 8.0);

  SELECT mu INTO lat FROM personal_priors WHERE user_id=p_user_id AND param='sleep_latency_min';
  lat := COALESCE(lat, 18);

  -- sleep as long as the morning allows (maximize sleep up to the deadline)
  tw  := w_latest;
  bed := tw - make_interval(mins => lat) - make_interval(secs => round(nstar*3600)::int);
  wd  := bed - make_interval(mins => p_winddown_min);

  target_wake := tw;
  wake_window_end := tw;
  wake_window_start := tw - interval '20 minutes';   -- Module 3 fires at a light moment in here
  target_bedtime := bed;
  winddown_start := wd;
  target_sleep_h := nstar;
  opp := round(EXTRACT(epoch FROM (tw - bed))/60.0)::int - lat;
  sleep_opportunity_min := opp;

  -- circadian sanity: is this wake before his natural rise?
  SELECT a.optimal_wake_hour, a.cbtmin_hour INTO ow, cbt FROM estimate_circadian_anchor(p_user_id, 21) a;
  wake_hr := extract(hour FROM tw AT TIME ZONE 'Europe/Berlin') + extract(minute FROM tw AT TIME ZONE 'Europe/Berlin')/60.0;

  parts := format('Lights out by %s, wind down from %s. Sleep ~%sh.',
                  to_char(bed AT TIME ZONE 'Europe/Berlin','HH24:MI'),
                  to_char(wd  AT TIME ZONE 'Europe/Berlin','HH24:MI'),
                  nstar);
  IF cbt IS NOT NULL AND wake_hr < cbt + 1 THEN
    parts := parts || format(' ⚠️ that wake (%s) is before your natural rise (~%s:00) — expect some grogginess.',
                             to_char(tw AT TIME ZONE 'Europe/Berlin','HH24:MI'), round(cbt+2));
  END IF;
  IF bed <= now_b THEN
    parts := parts || ' 🔴 You are already past the ideal bedtime — head to bed as soon as you can.';
  ELSIF wd <= now_b THEN
    parts := parts || ' 🟡 Start winding down now.';
  END IF;
  note := parts;
  RETURN NEXT;
END;$f$;

-- Convenience: plan from tomorrow's first calendar event (events table).
CREATE OR REPLACE FUNCTION public.plan_tonight_from_calendar(
  p_user_id uuid, p_prep_min int DEFAULT 45, p_travel_min int DEFAULT 0, p_winddown_min int DEFAULT 45
)
RETURNS TABLE(
  winddown_start timestamptz, target_bedtime timestamptz, target_wake timestamptz,
  wake_window_start timestamptz, wake_window_end timestamptz,
  target_sleep_h numeric, sleep_opportunity_min int, note text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE deadline timestamptz; tom date := (now() AT TIME ZONE 'Europe/Berlin')::date + 1;
BEGIN
  -- events stores date + start_time (time) separately; combine into a timestamptz
  SELECT min((date::timestamp + start_time::time) AT TIME ZONE 'Europe/Berlin') INTO deadline
  FROM events
  WHERE user_id=p_user_id AND date = tom AND COALESCE(all_day,false) = false AND start_time IS NOT NULL;

  IF deadline IS NULL THEN
    -- no event: default to his natural wake (circadian optimal) tomorrow
    DECLARE ow numeric;
    BEGIN
      SELECT optimal_wake_hour INTO ow FROM estimate_circadian_anchor(p_user_id,21);
      deadline := ((tom::timestamp) + make_interval(mins => round(COALESCE(ow,8)*60)::int)) AT TIME ZONE 'Europe/Berlin'
                  + make_interval(mins => p_prep_min + p_travel_min);
    END;
  END IF;

  RETURN QUERY SELECT * FROM plan_tonight(p_user_id, deadline, p_prep_min, p_travel_min, p_winddown_min);
END;$f$;

COMMENT ON FUNCTION public.plan_tonight IS
'v115 smart-alarm Module 6: backsolve a night from a wake deadline -> wake window -> bedtime -> wind-down start, using personal sleep need (Module 4) and circadian warning (Module 5). plan_tonight_from_calendar reads tomorrow''s first event.';
