-- v214 rollback: the v213 smart_wake_evaluate as it was live on 2026-10-12.
CREATE OR REPLACE FUNCTION public.smart_wake_evaluate(p_user_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(session_id uuid, should_fire boolean, reason text, stage text, wake_score integer, deep_prob numeric, slept_h_so_far numeric, target_h numeric, earliest_wake_at timestamp with time zone, target_wake_at timestamp with time zone, backstop_at timestamp with time zone, recovery_pct numeric, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s record; v_onset timestamptz; v_target numeric; floor_h numeric;
  v_earliest timestamptz; v_target_wake timestamptz; v_backstop timestamptz;
  sw_wake boolean; sw_score int; sw_dp numeric; sw_reason text;
  v_stage text; v_slept numeric;
  total_deep_min int; recent_hrv numeric; base_hrv numeric;
  hrv_rebound boolean; recovery_complete boolean; v_recpct numeric;
  v_should boolean := false; v_reason text; v_last_sample timestamptz;
  tz text := 'Europe/Berlin';
  v_need int; v_asleep int; v_aw6 int; v_n6 int; v_aw30 int; v_n30 int; v_deep4 int; v_aw4 int;
  v_alcohol boolean; v_last_min timestamptz; v_last_awake int; s5 record; s15 record;
  v_awake_now boolean; v_stopped boolean; v_light_ok boolean; v_blind_backstop timestamptz;
  v_last_any timestamptz; v_night_end timestamptz; v_night date;
BEGIN
  SELECT * INTO s FROM smart_wake_sessions
   WHERE user_id=p_user_id AND smart_wake_sessions.status IN ('armed','asleep','ready')
   ORDER BY armed_at DESC LIMIT 1;

  IF s.id IS NULL THEN
    session_id:=NULL; should_fire:=false; reason:='no_armed_session'; status:='none';
    RETURN NEXT; RETURN;
  END IF;

  v_target := COALESCE(s.target_h, 8.0);
  v_onset  := s.sleep_onset_at;

  -- v175: floor is 7h when no clock deadline was set (never wake him short on a free morning).
  -- With an explicit deadline the old 6h floor stands so a real flight/train alarm still lands.
  floor_h := CASE WHEN s.latest_wake_at IS NULL
                  THEN GREATEST(7.0, 0.7 * v_target)
                  ELSE GREATEST(6.0, 0.7 * v_target) END;

  -- ---- Onset detection / transition ----
  IF v_onset IS NULL THEN
    v_onset := detect_live_sleep_onset(p_user_id, s.armed_at, p_now);
    IF v_onset IS NOT NULL THEN
      v_earliest    := v_onset + make_interval(mins => round(floor_h*60)::int);
      v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int);
      -- v175: default backstop follows the sleep need instead of a flat 9.5h, so there is always a
      -- real ~1h light-sleep hunting window after target instead of the 26 min a 9.06h target left.
      v_backstop    := COALESCE(s.latest_wake_at,
                         GREATEST(v_onset + interval '8 hours',
                                  v_onset + make_interval(mins => round((v_target + 1.0)*60)::int)));
      UPDATE smart_wake_sessions
         SET status='asleep', sleep_onset_at=v_onset,
             earliest_wake_at=v_earliest, target_wake_at=v_target_wake,
             backstop_at=v_backstop, updated_at=now()
       WHERE id=s.id;
    ELSE
      IF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at THEN
        session_id:=s.id; should_fire:=true; reason:='deadline_no_onset';
        stage:='unknown'; wake_score:=100; deep_prob:=NULL; slept_h_so_far:=NULL;
        target_h:=v_target; earliest_wake_at:=NULL; target_wake_at:=NULL;
        backstop_at:=s.latest_wake_at; recovery_pct:=NULL; status:=s.status;
        RETURN NEXT; RETURN;
      ELSIF p_now >= s.armed_at + interval '20 hours' THEN
        session_id:=s.id; should_fire:=false; reason:='expire_no_onset'; status:='armed';
        target_h:=v_target; RETURN NEXT; RETURN;
      ELSE
        session_id:=s.id; should_fire:=false; reason:='awaiting_onset'; status:='armed';
        target_h:=v_target; RETURN NEXT; RETURN;
      END IF;
    END IF;
  ELSE
    v_earliest    := s.earliest_wake_at;
    v_target_wake := s.target_wake_at;
    v_backstop    := s.backstop_at;
    IF v_earliest IS NULL THEN v_earliest := v_onset + make_interval(mins => round(floor_h*60)::int); END IF;
    IF v_target_wake IS NULL THEN v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int); END IF;
    IF v_backstop IS NULL THEN
      v_backstop := COALESCE(s.latest_wake_at,
                      GREATEST(v_onset + interval '8 hours',
                               v_onset + make_interval(mins => round((v_target + 1.0)*60)::int)));
    END IF;
  END IF;

  -- v213: the clock counts minutes ASLEEP from the same stager as the morning summary (drinking-aware
  -- since v207), not wall time since onset. The need is learned from asleep hours, so the wall clock woke
  -- him ~50 min short and he slept on (7 of 21 fires in 60 days). Awake is checked at every step,
  -- including at the window end, and the app's stop / "I'm awake" log ends the session.
  v_slept := round(EXTRACT(epoch FROM (p_now - v_onset))/3600.0, 2);
  IF p_now < v_onset + interval '5 hours' THEN
    session_id:=s.id; should_fire:=false; reason:='safety_floor'; stage:='unknown';
    slept_h_so_far:=v_slept; target_h:=v_target; earliest_wake_at:=v_earliest;
    target_wake_at:=v_target_wake; backstop_at:=v_backstop; status:=COALESCE(s.status,'asleep');
    RETURN NEXT; RETURN;
  END IF;

  -- the night a minute belongs to runs 19:00 to 12:00 (Berlin), as in sleep_night_minutes
  v_night := ((p_now AT TIME ZONE tz) + interval '5 hours')::date;
  v_night_end := (v_night::text || ' 12:00:00')::timestamp AT TIME ZONE tz;

  -- v_last_any counts minutes before the stager's own onset too: data flowing, him not asleep yet, is not a dead strap
  SELECT count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage <> 'awake'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '6 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '6 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '30 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '30 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'deep'  AND m.n_m_ts > p_now - interval '4 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '4 minutes'),
         bool_or(m.n_alcohol), max(m.n_m_ts) FILTER (WHERE NOT m.n_pre_onset), max(m.n_m_ts)
    INTO v_asleep, v_aw6, v_n6, v_aw30, v_n30, v_deep4, v_aw4, v_alcohol, v_last_min, v_last_any
    FROM sleep_night_minutes(p_user_id, v_night) m
   WHERE m.n_m_ts <= p_now;
  v_asleep := COALESCE(v_asleep, 0);

  -- the stage of the last minutes the strap did send, for when it went quiet
  SELECT count(*) FILTER (WHERE m.n_stage = 'awake') INTO v_last_awake
    FROM sleep_night_minutes(p_user_id, v_night) m
   WHERE NOT m.n_pre_onset AND m.n_m_ts <= v_last_min AND m.n_m_ts > v_last_min - interval '6 minutes';


  v_need := round(v_target * 60)::int;
  v_slept := round(v_asleep / 60.0, 2);
  v_target_wake := p_now + make_interval(mins => GREATEST(v_need - v_asleep, 0));
  v_earliest    := p_now + make_interval(mins => GREATEST(v_need - 30 - v_asleep, 0));
  v_blind_backstop := COALESCE(s.latest_wake_at,
                        LEAST(v_onset + make_interval(mins => v_need + 120),
                              GREATEST(v_night_end, v_onset + make_interval(mins => v_need))));
  v_backstop    := LEAST(v_blind_backstop, p_now + make_interval(mins => GREATEST(v_need + 45 - v_asleep, 0)));

  SELECT * INTO s5  FROM live_sleep_stage(p_user_id, p_now, 5)  z;
  SELECT * INTO s15 FROM live_sleep_stage(p_user_id, p_now, 15) z;
  v_awake_now := (v_n6 >= 4 AND v_aw6 >= v_n6 - 1)
              OR (COALESCE(s5.p_awake, 0) >= 0.35 AND COALESCE(s15.p_awake, 0) >= 0.30);

  v_stopped := EXISTS (SELECT 1 FROM bridge_logs b
                        WHERE b.user_id = p_user_id
                          AND b.category IN ('manual_wake_up','evt_alarm_stopped','smart_alarm_stopped')
                          AND b.created_at > v_onset + interval '3 hours' AND b.created_at <= p_now);

  -- light/REM must hold: the live check (now and 3 min ago) and no deep or awake minute in the last 4
  SELECT w.wake, w.wake_score, w.deep_prob, w.reason INTO sw_wake, sw_score, sw_dp, sw_reason
    FROM should_wake_now(p_user_id, p_now - interval '1 minute', p_now + interval '1 day', p_now) w;
  v_light_ok := sw_wake IS TRUE AND COALESCE(v_deep4, 0) = 0 AND COALESCE(v_aw4, 0) <= 1;

  v_stage := CASE WHEN v_awake_now THEN 'awake'
                  WHEN sw_dp IS NULL THEN 'unknown'
                  WHEN sw_dp >= 0.40 OR COALESCE(v_deep4,0) > 0 THEN 'deep'
                  ELSE 'light_rem' END;
  v_recpct := round(100 * LEAST(1.0, v_asleep::numeric / NULLIF(v_need, 0)));

  -- ---- Decision ----
  IF v_stopped THEN
    v_should := false; v_reason := 'stopped_by_you';
  ELSIF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at THEN
    v_should := true;  v_reason := 'deadline';                       -- a deadline is never cancelled
  ELSIF p_now >= v_night_end THEN
    v_should := false; v_reason := 'night_over';                     -- the night's minutes stop at 12:00; he is up
  ELSIF v_last_any IS NULL OR v_last_any < p_now - interval '15 minutes' THEN
    IF COALESCE(v_last_awake, 0) >= 4 THEN
      v_should := false; v_reason := 'woke_on_own';                  -- the strap went quiet with him awake
    ELSIF v_asleep >= 300 THEN
      -- replay of 60 days: every silence after 5 h asleep was him getting up (strap off, phone left);
      -- ringing hours later reached him awake. A strap that dies early in the night still rings below.
      v_should := false; v_reason := 'strap_quiet_late';
    ELSIF p_now >= v_blind_backstop THEN
      v_should := true;  v_reason := 'backstop_blind';
    ELSE
      v_should := false; v_reason := 'no_live_data_hold';
    END IF;
  ELSIF v_last_min IS NULL THEN
    v_should := false; v_reason := 'not_asleep_yet';                 -- data flows, the stager has not seen him fall asleep
  ELSIF v_awake_now AND v_n30 >= 24 AND v_aw30 >= 20 THEN
    v_should := false; v_reason := 'woke_on_own';                    -- up for 20 of the last 30 min: he is up, never ring
  ELSIF v_awake_now THEN
    v_should := false; v_reason := 'awake_hold';                     -- awake for now: never ring into it, keep the night open
  ELSIF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at - interval '30 minutes' AND v_light_ok THEN
    v_should := true;  v_reason := 'deadline_light';                 -- inside the last 30 min before a deadline, take light sleep
  ELSIF v_asleep < v_need - 30 THEN
    v_should := false; v_reason := 'need_not_met';
  ELSIF v_light_ok THEN
    v_should := true;  v_reason := 'need_met_light';
  ELSIF v_asleep >= v_need + 45 OR p_now >= v_blind_backstop THEN
    v_should := true;  v_reason := 'backstop_reached';
  ELSIF v_asleep >= v_need + 30 AND v_stage <> 'deep' THEN
    v_should := true;  v_reason := 'window_end';
  ELSE
    v_should := false; v_reason := CASE WHEN v_stage = 'deep' THEN 'deep_hold' ELSE 'light_hold' END;
  END IF;

  session_id := s.id; should_fire := v_should; reason := v_reason;
  stage := v_stage; wake_score := sw_score; deep_prob := sw_dp;
  slept_h_so_far := v_slept; target_h := v_target;
  earliest_wake_at := v_earliest; target_wake_at := v_target_wake;
  backstop_at := v_backstop; recovery_pct := v_recpct;
  status := CASE WHEN v_should THEN 'ready' ELSE COALESCE(s.status,'asleep') END;
  RETURN NEXT;
END;$function$;
