-- v208: one rule for which night a "drinking tonight" tap belongs to, used by the writer, the alarm and the stager.
--
-- set_drinking_tonight, refresh_tonight_plan, plan_tonight_auto and plan_tonight_alcohol all took today+1 as
-- "tonight". After midnight that is the following night: a 03:22 tap was stored for the following night, so the
-- alarm planned the next night as a drinking night and the night in progress was staged sober (fixed on the read
-- side in v207). night_of() now names the night everywhere: before 08:00 the night in progress, from 08:00 the
-- coming one. Evening behaviour is unchanged. The one mis-dated flag is moved to its night.

CREATE OR REPLACE FUNCTION public.night_of(p_ts timestamp with time zone)
RETURNS date
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  -- v208: the night a moment belongs to, named by the morning it ends on. 00:00-07:59 is the night in progress,
  -- from 08:00 on it is the coming night. The one place this rule lives.
  SELECT ((p_ts AT TIME ZONE 'Europe/Berlin') + interval '16 hours')::date
$function$;

CREATE OR REPLACE FUNCTION public.drinking_flagged_night(p_user_id uuid, p_night date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- v207: which night a "drinking tonight" tap belongs to is decided by WHEN it was tapped, not by flag_date.
  -- set_drinking_tonight always dates the flag today+1, so a tap after midnight (03:22) landed on
  -- the night after. A tap from 08:00 on belongs to the coming night, a tap
  -- between midnight and 08:00 to the night in progress.
  SELECT EXISTS (
    SELECT 1 FROM alcohol_flags af
    WHERE af.user_id = p_user_id AND af.manual_drinking
      AND public.night_of(af.created_at) = p_night)
$function$;

CREATE OR REPLACE FUNCTION public.is_alcohol_mode(p_user_id uuid, p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Berlin'::text))::date)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE m boolean; d boolean;
BEGIN
  IF drinking_flagged_night(p_user_id, p_date) THEN RETURN true; END IF;   -- v208: same rule as the stager
  BEGIN
    d := detect_overnight_alcohol(p_user_id, p_date, 'Europe/Berlin');
  EXCEPTION WHEN OTHERS THEN d := false;
  END;
  RETURN COALESCE(d,false);
END;$function$;

CREATE OR REPLACE FUNCTION public.set_drinking_tonight(p_user_id uuid, p_drinking boolean DEFAULT true, p_for_date date DEFAULT public.night_of(now()))
 RETURNS alcohol_flags
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r public.alcohol_flags;
BEGIN
  INSERT INTO alcohol_flags(user_id, flag_date, manual_drinking)
  VALUES (p_user_id, p_for_date, p_drinking)
  ON CONFLICT (user_id, flag_date)
  DO UPDATE SET manual_drinking = EXCLUDED.manual_drinking, created_at = now()
  RETURNING * INTO r;
  -- if this flag is for the upcoming night, update what the app downloads now
  IF p_for_date = public.night_of(now()) THEN   -- v208: today+1 put a tap after midnight on the following night
    PERFORM refresh_tonight_plan(p_user_id);
  END IF;
  RETURN r;
END;$function$;

CREATE OR REPLACE FUNCTION public.refresh_tonight_plan(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE pd date := public.night_of(now()); pj jsonb;   -- v208
BEGIN
  pj := plan_tonight_auto(p_user_id);
  INSERT INTO smart_alarm_plan(user_id, plan_date, plan, mode, computed_at)
  VALUES (p_user_id, pd, pj, pj->>'mode', now())
  ON CONFLICT (user_id, plan_date)
  DO UPDATE SET plan=EXCLUDED.plan, mode=EXCLUDED.mode, computed_at=now();
  RETURN pj;
END;$function$;

CREATE OR REPLACE FUNCTION public.plan_tonight_auto(p_user_id uuid, p_prep_min integer DEFAULT 45, p_travel_min integer DEFAULT 0, p_winddown_min integer DEFAULT 45)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  tom date := public.night_of(now());   -- v208: after midnight the coming wake is today, not tomorrow
  is_alc boolean; deadline timestamptz; r jsonb;
BEGIN
  is_alc := is_alcohol_mode(p_user_id, tom);

  SELECT min((date::timestamp + start_time::time) AT TIME ZONE 'Europe/Berlin') INTO deadline
  FROM events
  WHERE user_id=p_user_id AND date=tom AND COALESCE(all_day,false)=false AND start_time IS NOT NULL;

  IF is_alc THEN
    SELECT to_jsonb(a) INTO r FROM plan_tonight_alcohol(p_user_id, deadline, p_prep_min, p_travel_min) a;
    r := r || jsonb_build_object('mode','alcohol');
  ELSE
    SELECT to_jsonb(b) INTO r FROM plan_tonight_from_calendar(p_user_id, p_prep_min, p_travel_min, p_winddown_min) b;
    r := r || jsonb_build_object('mode','normal');
  END IF;
  RETURN r;
END;$function$;

CREATE OR REPLACE FUNCTION public.plan_tonight_alcohol(p_user_id uuid, p_wake_deadline timestamp with time zone DEFAULT NULL::timestamp with time zone, p_prep_min integer DEFAULT 45, p_travel_min integer DEFAULT 0)
 RETURNS TABLE(alcohol_mode boolean, target_bedtime timestamp with time zone, target_wake timestamp with time zone, wake_window_start timestamp with time zone, wake_window_end timestamp with time zone, hard_backstop timestamp with time zone, target_sleep_h numeric, hr_floor numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  nstar numeric; floor_hr numeric; w_latest timestamptz; tw timestamptz;
  tz text := 'Europe/Berlin';
  tom date := public.night_of(now());   -- v208: after midnight the 09:00/12:00 bounds are today's
  humane_min timestamptz; backstop timestamptz; parts text;
  alc boolean;
BEGIN
  -- v153 (audit #36): alcohol_mode was hardcoded true, so any DIRECT caller asking
  -- "is tonight an alcohol night?" always got the drunk-night 9am-earliest / 12:00-backstop
  -- schedule, even stone sober. Compute the REAL boolean for the target night (tom).
  -- (plan_tonight_auto already gates on is_alcohol_mode before calling this, so its
  -- routing is unaffected; this fixes the misleading boolean/plan for direct callers.)
  alc := is_alcohol_mode(p_user_id, tom);

  SELECT mu INTO nstar FROM personal_priors
   WHERE user_id=p_user_id AND param='alcohol_sleep_target_h';
  nstar := COALESCE(nstar, 9.0);
  floor_hr := alcohol_hr_floor(p_user_id);

  -- humane drunk-night earliest-consider wake = 09:00 Berlin; hard backstop = 12:00.
  humane_min := ((tom::timestamp) + interval '9 hours')  AT TIME ZONE tz;
  backstop   := ((tom::timestamp) + interval '12 hours') AT TIME ZONE tz;

  IF p_wake_deadline IS NOT NULL THEN
    -- a real commitment: maximize sleep up to it (can't skip a flight), flag the cost
    w_latest := p_wake_deadline - make_interval(mins => p_prep_min + p_travel_min);
    tw := w_latest;
    backstop := w_latest;                            -- the commitment IS the hard stop
    parts := format('🍷 Alcohol mode + a hard %s commitment. Sleeping you to the last safe minute (%s) — no earlier. Expect low recovery; water + salt before bed, no caffeine before noon.',
                    to_char(p_wake_deadline AT TIME ZONE tz,'HH24:MI'),
                    to_char(tw AT TIME ZONE tz,'HH24:MI'));
  ELSE
    -- NO commitment: no early alarm at all. The back-half rebound is sacred.
    tw := humane_min;
    parts := format('🍷 Alcohol mode, nothing hard tomorrow — no early alarm. Smart-wake only starts watching at %s, hard backstop %s. Your deep sleep rebounds in the back half of the night as it clears; cutting that short is exactly what wrecked you before, so we don''t.',
                    to_char(humane_min AT TIME ZONE tz,'HH24:MI'),
                    to_char(backstop   AT TIME ZONE tz,'HH24:MI'));
  END IF;

  -- Sober night: return the honest boolean and a sober note so a direct caller isn't
  -- shown a drunk-night narrative. The schedule fields stay populated (shape preserved);
  -- callers that gate on alcohol_mode=false should defer to the normal sober planner
  -- (plan_tonight_from_calendar) — which is exactly what plan_tonight_auto does.
  IF NOT alc THEN
    parts := '🌙 Not an alcohol night — use your normal wake plan (plan_tonight_from_calendar). This alcohol schedule is informational only.';
  END IF;

  alcohol_mode      := alc;
  target_wake       := tw;
  wake_window_start := tw;
  wake_window_end   := backstop;
  hard_backstop     := backstop;
  target_sleep_h    := nstar;
  hr_floor          := floor_hr;
  target_bedtime    := tw - make_interval(secs => round(nstar*3600)::int);  -- informational
  note := parts;
  RETURN NEXT;
END;$function$;

-- Flags tapped after midnight since the bug surfaced move to the night they were tapped in.
UPDATE public.alcohol_flags af SET flag_date = public.night_of(af.created_at)
 WHERE af.user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff' AND af.manual_drinking AND af.created_at >= '2026-10-10'
   AND af.flag_date = public.night_of(af.created_at) + 1
   AND NOT EXISTS (SELECT 1 FROM public.alcohol_flags x WHERE x.user_id = af.user_id AND x.flag_date = public.night_of(af.created_at));

GRANT EXECUTE ON FUNCTION public.night_of(timestamp with time zone) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.drinking_flagged_night(uuid, date) TO anon;
GRANT EXECUTE ON FUNCTION public.sleep_night_minutes(uuid, date, text) TO anon;

SELECT public.refresh_tonight_plan('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);
