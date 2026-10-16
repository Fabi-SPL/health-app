-- v220 rollback: plan_tonight_alcohol as of v208.
BEGIN;
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
COMMIT;
