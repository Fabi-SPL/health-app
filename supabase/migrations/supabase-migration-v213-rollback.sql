-- v213 rollback: the v175 evaluator (wall-clock target, awake veto off near the backstop) and its cron.
UPDATE public.smart_wake_sessions SET status='cancelled' WHERE status='done';
ALTER TABLE public.smart_wake_sessions DROP CONSTRAINT IF EXISTS smart_wake_sessions_status_check;
ALTER TABLE public.smart_wake_sessions ADD CONSTRAINT smart_wake_sessions_status_check
  CHECK (status = ANY (ARRAY['armed','asleep','ready','fired','cancelled','expired']));
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

  v_slept := round(EXTRACT(epoch FROM (p_now - v_onset))/3600.0, 2);

  SELECT w.wake, w.wake_score, w.deep_prob, w.reason
    INTO sw_wake, sw_score, sw_dp, sw_reason
  FROM should_wake_now(p_user_id, v_earliest, v_backstop, p_now) w;

  v_stage := CASE WHEN sw_dp IS NULL THEN 'unknown'
                  WHEN sw_dp >= 0.40 THEN 'deep'
                  ELSE 'light_rem' END;

  SELECT count(DISTINCT date_trunc('minute', recorded_at))
    INTO total_deep_min
  FROM realtime_health
  WHERE user_id=p_user_id AND sleep_stage='deep'
    AND recorded_at >= v_onset AND recorded_at <= p_now;
  total_deep_min := COALESCE(total_deep_min, 0);

  SELECT avg(hrv_rmssd) INTO recent_hrv FROM realtime_health
  WHERE user_id=p_user_id AND hrv_rmssd>0
    AND recorded_at >= p_now - interval '10 minutes' AND recorded_at <= p_now;
  base_hrv := (SELECT baseline_hrv_avg FROM current_state WHERE user_id=p_user_id);

  hrv_rebound := recent_hrv IS NOT NULL AND base_hrv IS NOT NULL AND recent_hrv >= base_hrv;
  recovery_complete := total_deep_min >= 100 AND hrv_rebound;

  v_recpct := round(100 * (
        0.40 * LEAST(1.0, v_slept / NULLIF(v_target,0))
      + 0.35 * LEAST(1.0, total_deep_min / 100.0)
      + 0.25 * LEAST(1.0, COALESCE(recent_hrv,0) / NULLIF(base_hrv,0))
    ));

  -- ---- Decision ----
  IF p_now < v_earliest THEN
    v_should := false; v_reason := 'safety_floor';
  ELSIF p_now >= v_backstop THEN
    v_should := true;  v_reason := 'backstop_reached';
  ELSIF sw_wake IS TRUE THEN
    IF p_now >= v_target_wake THEN
      v_should := true;  v_reason := CASE WHEN recovery_complete THEN 'recovered_early' ELSE 'target_reached' END;
    ELSIF p_now >= v_backstop - interval '20 minutes' THEN
      v_should := true;  v_reason := 'near_backstop_light';
    ELSE
      v_should := false; v_reason := 'light_hold_for_target';
    END IF;
  ELSE
    IF sw_dp IS NULL THEN v_should := false; v_reason := 'no_live_data_hold';
    ELSE v_should := false; v_reason := 'deep_hold'; END IF;
  END IF;

  session_id := s.id; should_fire := v_should; reason := v_reason;
  stage := v_stage; wake_score := sw_score; deep_prob := sw_dp;
  slept_h_so_far := v_slept; target_h := v_target;
  earliest_wake_at := v_earliest; target_wake_at := v_target_wake;
  backstop_at := v_backstop; recovery_pct := v_recpct;
  status := CASE WHEN v_should THEN 'ready' ELSE COALESCE(s.status,'asleep') END;
  RETURN NEXT;
END;$function$
;
CREATE OR REPLACE FUNCTION public.smart_wake_cron(p_now timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  u uuid; ev record; fired_count int := 0; v_title text; v_body text; tz text := 'Europe/Berlin';
  v_ctx jsonb;
BEGIN
  FOR u IN
    SELECT DISTINCT user_id FROM smart_wake_sessions
     WHERE smart_wake_sessions.status IN ('armed','asleep','ready')
  LOOP
    SELECT * INTO ev FROM smart_wake_evaluate(u, p_now);
    IF ev.should_fire THEN
      IF ev.reason IN ('recovered_early') THEN
        v_title := '☀️ Perfect wake window';
        v_body  := 'You banked what you needed — HRV''s back up and you''re in light sleep at '||ev.slept_h_so_far||'h. This is the clean exit. Up you get.';
      ELSIF ev.reason = 'target_reached' THEN
        v_title := '☀️ Right on target';
        v_body  := 'You''ve hit your '||ev.target_h||'h and you''re in light sleep — the smoothest moment to wake. Morning.';
      ELSIF ev.reason = 'near_backstop_light' THEN
        v_title := '☀️ Catching your light window';
        v_body  := 'Close to your latest time and you just surfaced into light sleep — grabbing it now so you wake gentle.';
      ELSE
        v_title := '⏰ Time to wake';
        v_body  := 'This is your hard limit — up you get. Couldn''t find a lighter window in time, but you''re at '||COALESCE(ev.slept_h_so_far::text,'your deadline')||'h.';
      END IF;

      UPDATE smart_wake_sessions
         SET status='fired', fired_at=p_now, fired_reason=ev.reason,
             fired_stage=ev.stage, wake_score=ev.wake_score, recovery_pct=ev.recovery_pct, updated_at=now()
       WHERE id=ev.session_id;

      v_ctx := jsonb_build_object(
          'kind','smart_wake', 'priority','critical', 'alarm', true, 'session_id', ev.session_id,
          'reason', ev.reason, 'stage', ev.stage, 'wake_score', ev.wake_score,
          'slept_h', ev.slept_h_so_far, 'target_h', ev.target_h, 'recovery_pct', ev.recovery_pct);

      -- (1) history/audit row
      INSERT INTO notification_queue(user_id, type, scheduled_for, sent_at, title, body, context_data)
      VALUES (u, 'smart_wake', p_now, NULL, v_title, v_body, v_ctx);

      -- (2) delivery row — iOS NotificationListener polls `nudges` (channels @> {push}, deliver_at recent).
      -- priority='alarm' + metadata.kind='smart_wake' => client escalates to strap-buzz actuator.
      INSERT INTO nudges(user_id, title, message, deliver_at, delivered_at,
                         priority, channels, status, source, related_type, related_id, metadata)
      VALUES (u, v_title, v_body, p_now, p_now,
              'alarm', ARRAY['push'], 'delivered', 'health', 'health', ev.session_id, v_ctx);

      fired_count := fired_count + 1;
    ELSIF ev.reason = 'expire_no_onset' THEN
      UPDATE smart_wake_sessions SET status='expired', updated_at=now()
       WHERE id=ev.session_id AND smart_wake_sessions.status='armed';
    END IF;
  END LOOP;
  RETURN fired_count;
END;$function$
;
CREATE OR REPLACE FUNCTION public.smart_wake_auto_arm()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  u uuid; armed_count int := 0; berlin_hour int;
BEGIN
  berlin_hour := EXTRACT(hour FROM now() AT TIME ZONE 'Europe/Berlin')::int;
  -- arm window: 20:00–02:59 Berlin
  IF NOT (berlin_hour >= 20 OR berlin_hour < 3) THEN RETURN 0; END IF;

  FOR u IN SELECT DISTINCT user_id FROM smart_wake_sessions
  LOOP
    -- any session touched in the last 12h (armed, fired, or user-cancelled)
    -- means tonight is already decided: never double-arm, never override a cancel.
    IF EXISTS (SELECT 1 FROM smart_wake_sessions s
                WHERE s.user_id = u AND s.armed_at > now() - interval '12 hours') THEN
      CONTINUE;
    END IF;
    PERFORM arm_smart_wake(u, NULL, 30);
    armed_count := armed_count + 1;
  END LOOP;
  RETURN armed_count;
END;$function$
;
DROP TABLE IF EXISTS public.smart_wake_trace;
