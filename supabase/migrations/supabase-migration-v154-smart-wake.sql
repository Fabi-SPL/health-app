-- ============================================================================
-- Migration v154 — Adaptive Sleep-Need + Onset-Anchored Smart-Wake Engine
-- ============================================================================
-- Server-only (Hetzner self-hosted Postgres). NOT git-committed to the public
-- iOS repo. Deployed live 2026-07-10 via /pg/query.
--
-- WHAT THIS IS: the "wake me at the perfect time" button. Fabi taps it before
-- bed (optionally with a hard latest-wake deadline). The server:
--   1. computes how much sleep he actually needs TONIGHT (not a fixed 7.5h),
--   2. anchors the countdown to his REAL sleep ONSET (not the button press),
--   3. wakes him in a LIGHT-sleep window near the target — EARLIER if he
--      recovered exceptionally well (deep banked + HRV rebound), LATER up to a
--      humane cap / his deadline — NEVER in deep sleep, NEVER below a hard floor.
--
-- BUILDS ON v112+ smart-alarm + v153 fixes. REUSES (never reinvents):
--   should_wake_now()        — no-deep + light-persistence stage oracle (v153)
--   current_deep_probability — HR-near-floor deep marker
--   detect_sleep_window()    — onset/stage reference geometry (v151/v153)
--   compute_sleep_debt()     — 7-day debt (base 8.0)
--   personal_priors.optimal_sleep_hours = 8.0, current_state.baseline_resting_hr = 49
--
-- SAFETY INVARIANTS:
--   * HARD floor: never signal before onset + max(6.0h, 0.7*target).
--   * never fire while stage=deep; should_wake_now requires light persisted.
--   * humane backstop: deadline if given, else onset + 9.5h — fire regardless then.
--   * fail-safe: missing data / no onset => never fire early, only backstop/deadline.
--
-- CLIENT TODO (cannot be built server-side): the iOS app must turn a pending
-- notification_queue row of type='smart_wake' (context_data.alarm=true,
-- priority='critical') into an actual on-device *critical/time-sensitive* local
-- alarm that bypasses silent/DND. A normal web-push will not reliably wake a
-- sleeping person.
-- ============================================================================

-- ============ 0. delivery prerequisite: widen nudges.priority ============
-- The smart-wake fire is delivered as a `nudges` row (the table the iOS
-- NotificationListener polls). priority='alarm' is a NEW value the client keys
-- off to escalate to the strap-buzz actuator. Additive, backward-compatible.
ALTER TABLE public.nudges DROP CONSTRAINT IF EXISTS nudges_priority_check;
ALTER TABLE public.nudges ADD CONSTRAINT nudges_priority_check
  CHECK (priority = ANY (ARRAY['voice'::text,'visual'::text,'silent'::text,'alarm'::text]));

-- ============ 1. compute_sleep_need ============
CREATE OR REPLACE FUNCTION public.compute_sleep_need(
  p_user_id uuid,
  p_date date DEFAULT (((now() AT TIME ZONE 'Europe/Berlin'::text))::date + 1)
)
RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric,
              d_quality numeric, d_circadian numeric, debt_raw numeric, note text)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  base numeric; debt numeric; dd numeric; ds numeric := 0; dq numeric := 0; dc numeric := 0;
  ystrain numeric; strainbase numeric; yhrv numeric; hrvbase numeric;
  yeff numeric; ydeep numeric; ycons numeric; v_last date;
  deepnorm numeric := 105;      -- Fabi's ~105-116 min deep norm (finding #20)
  parts text;
BEGIN
  -- Base: his learned optimal (personal_priors, v153 => 8.0).
  SELECT mu INTO base FROM personal_priors
   WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- Homeostatic debt term: research repays ~25%/night, NOT 1:1. Capped at 0.75h so a
  -- big accumulated debt nudges the target up gently over several nights instead of
  -- maxing it out in one (mirrors target_sleep_duration's humane 0.5 cap, a touch higher
  -- for the "perfect wake" premium path).
  debt := COALESCE(compute_sleep_debt(p_user_id), 0);
  dd := round(LEAST(0.75, 0.25 * debt), 2);

  -- Most-recent completed night (drives strain + quality terms).
  SELECT metric_date, strain_score, hrv_avg, sleep_efficiency_pct, deep_sleep_min, sleep_consistency_pct
    INTO v_last, ystrain, yhrv, yeff, ydeep, ycons
    FROM health_metrics
   WHERE user_id=p_user_id AND sleep_hours > 0
   ORDER BY metric_date DESC LIMIT 1;

  -- Strain term: yesterday's training/stress load vs his 14-day baseline raises need
  -- (sympathetic tone up, needs more restorative sleep). Continuous, capped 0.5.
  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  IF ystrain IS NOT NULL AND strainbase IS NOT NULL AND strainbase > 0 AND ystrain > strainbase THEN
    ds := ds + LEAST(0.4, 0.4 * ((ystrain / strainbase) - 1));
  END IF;
  -- Suppressed day-HRV vs baseline = incomplete autonomic recovery => a little more sleep.
  hrvbase := COALESCE(
    (SELECT baseline_hrv_avg FROM current_state WHERE user_id=p_user_id),
    (SELECT avg(hrv_avg) FROM health_metrics WHERE user_id=p_user_id AND hrv_avg>0 AND metric_date >= CURRENT_DATE - 14));
  IF yhrv IS NOT NULL AND hrvbase IS NOT NULL AND yhrv < 0.90 * hrvbase THEN
    ds := ds + 0.15;
  END IF;
  ds := round(LEAST(0.5, ds), 2);

  -- Quality term: poor efficiency or short deep last night = the sleep was less
  -- restorative, so tonight needs more. Capped 0.5.
  IF yeff IS NOT NULL AND yeff < 85 THEN
    dq := dq + LEAST(0.4, 0.4 * ((85 - yeff) / 15.0));
  END IF;
  IF ydeep IS NOT NULL AND ydeep < deepnorm - 15 THEN
    dq := dq + 0.15;
  END IF;
  dq := round(LEAST(0.5, dq), 2);

  -- Circadian term: irregular recent bedtimes (low consistency) = weaker circadian
  -- anchoring, needs a touch more buffer. Small, capped 0.25.
  IF ycons IS NOT NULL AND ycons < 70 THEN
    dc := LEAST(0.25, 0.25 * ((70 - ycons) / 40.0));
  END IF;
  dc := round(dc, 2);

  target_h    := round(LEAST(9.5, GREATEST(6.0, base + dd + ds + dq + dc)), 2);
  base_h      := base;
  d_debt      := dd;
  d_strain    := ds;
  d_quality   := dq;
  d_circadian := dc;
  debt_raw    := round(debt, 2);

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || dd || ' debt (' || round(debt,1) || 'h owed)'; END IF;
  IF ds > 0 THEN parts := parts || ' +' || ds || ' strain'; END IF;
  IF dq > 0 THEN parts := parts || ' +' || dq || ' quality'; END IF;
  IF dc > 0 THEN parts := parts || ' +' || dc || ' circadian'; END IF;
  note := parts || ' -> aim for ' || target_h || 'h tonight';
  RETURN NEXT;
END;$function$;

-- ============ 2. smart_wake_sessions table + RLS ============
CREATE TABLE IF NOT EXISTS public.smart_wake_sessions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL,
  armed_at        timestamptz NOT NULL DEFAULT now(),
  latest_wake_at  timestamptz,                 -- optional hard deadline (his cap)
  prep_min        integer NOT NULL DEFAULT 30,
  target_h        numeric,                       -- tonight's computed need
  base_h          numeric,
  d_debt          numeric,
  d_strain        numeric,
  d_quality       numeric,
  d_circadian     numeric,
  status          text NOT NULL DEFAULT 'armed'
                    CHECK (status IN ('armed','asleep','ready','fired','cancelled','expired')),
  sleep_onset_at  timestamptz,                   -- detected real onset (anchor)
  earliest_wake_at timestamptz,                  -- onset + max(6h, 0.7*target) safety floor
  target_wake_at  timestamptz,                   -- onset + target_h
  backstop_at     timestamptz,                   -- deadline or onset + 9.5h humane cap
  fired_at        timestamptz,
  fired_reason    text,
  fired_stage     text,
  wake_score      integer,
  recovery_pct    numeric,
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- At most one live session per user (armed/asleep/ready).
CREATE UNIQUE INDEX IF NOT EXISTS uq_smart_wake_active
  ON public.smart_wake_sessions(user_id)
  WHERE status IN ('armed','asleep','ready');

CREATE INDEX IF NOT EXISTS idx_smart_wake_status
  ON public.smart_wake_sessions(status, armed_at);

ALTER TABLE public.smart_wake_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users read own smart_wake" ON public.smart_wake_sessions;
CREATE POLICY "Users read own smart_wake" ON public.smart_wake_sessions
  FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users insert own smart_wake" ON public.smart_wake_sessions;
CREATE POLICY "Users insert own smart_wake" ON public.smart_wake_sessions
  FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "Users update own smart_wake" ON public.smart_wake_sessions;
CREATE POLICY "Users update own smart_wake" ON public.smart_wake_sessions
  FOR UPDATE USING (auth.uid() = user_id);


-- ============ 3. detect_live_sleep_onset ============
CREATE OR REPLACE FUNCTION public.detect_live_sleep_onset(
  p_user_id uuid,
  p_since   timestamptz,
  p_now     timestamptz DEFAULT now(),
  p_user_tz text DEFAULT 'Europe/Berlin'
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  rhr numeric; night_p05 int; adj int; thresh numeric; onset timestamptz;
BEGIN
  -- Resting-HR anchor: current_state (p05 baseline, ~49) -> 30d baseline median -> 50.
  rhr := COALESCE(
    (SELECT baseline_resting_hr FROM current_state WHERE user_id=p_user_id),
    (SELECT median FROM personal_baselines WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30),
    50);

  -- Adaptive onset threshold: mirror detect_sleep_window's sober geometry so a hot/stressed
  -- night with an elevated floor is still captured. Onset = HR settling into his sleeping band.
  SELECT round(percentile_cont(0.05) WITHIN GROUP (ORDER BY heart_rate))::int
    INTO night_p05
  FROM realtime_health
  WHERE user_id=p_user_id AND recorded_at >= p_since AND recorded_at < p_now
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  IF night_p05 IS NULL THEN RETURN NULL; END IF;   -- FAIL SAFE: no data
  adj := 12 + GREATEST(0, night_p05 - 54);
  thresh := GREATEST(rhr + 11, LEAST(80, night_p05 + adj));

  WITH mb AS (
    SELECT date_trunc('minute', recorded_at) AS m_ts,
           avg(heart_rate)::numeric AS hr_avg,
           avg(COALESCE(accel_mag_mg, 0))::numeric AS accel_avg,
           avg(hrv_rmssd) FILTER (WHERE hrv_rmssd>0)::numeric AS hrv_avg
    FROM realtime_health
    WHERE user_id=p_user_id AND recorded_at >= p_since AND recorded_at < p_now
      AND heart_rate IS NOT NULL AND heart_rate > 30
    GROUP BY 1
  ),
  smoothed AS (
    SELECT m_ts, hr_avg, accel_avg, hrv_avg,
           avg(hr_avg) OVER (ORDER BY m_ts ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS hr_smooth
    FROM mb
  ),
  flagged AS (
    -- low HR (sleeping band) AND low motion if motion is actually recorded (else pass).
    SELECT m_ts,
           CASE WHEN hr_smooth < thresh
                 AND (accel_avg IS NULL OR accel_avg < 40) THEN 1 ELSE 0 END AS is_low
    FROM smoothed
  ),
  sustained AS (
    SELECT m_ts, is_low,
      SUM(is_low) OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 4 FOLLOWING) AS fwd5,
      COUNT(*)    OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 4 FOLLOWING) AS n5
    FROM flagged
  )
  SELECT MIN(m_ts) INTO onset
  FROM sustained
  WHERE fwd5 = 5 AND n5 = 5;   -- >=5 consecutive sub-threshold minutes

  RETURN onset;
END;$function$;

-- ============ 4. arm_smart_wake + cancel_smart_wake ============
CREATE OR REPLACE FUNCTION public.arm_smart_wake(
  p_user_id uuid,
  p_latest_wake timestamptz DEFAULT NULL,
  p_prep_min integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  sid uuid; floor_h numeric; note text; dl_label text; tz text := 'Europe/Berlin';
  v_target numeric; v_base numeric; v_dd numeric; v_ds numeric; v_dq numeric; v_dc numeric; v_note text;
  v_below_floor boolean := false; v_floor_reach timestamptz;
BEGIN
  SELECT csn.target_h, csn.base_h, csn.d_debt, csn.d_strain, csn.d_quality, csn.d_circadian, csn.note
    INTO v_target, v_base, v_dd, v_ds, v_dq, v_dc, v_note
  FROM compute_sleep_need(p_user_id, ((now() AT TIME ZONE tz)::date + 1)) csn;

  -- one live session at a time: retire any prior active one.
  UPDATE smart_wake_sessions
     SET status='cancelled', updated_at=now(),
         notes = COALESCE(notes,'') || ' [superseded by new arm ' || to_char(now(),'HH24:MI') || ']'
   WHERE user_id=p_user_id AND status IN ('armed','asleep','ready');

  floor_h := round(GREATEST(6.0, 0.7 * v_target), 2);

  -- Sub-floor deadline guard: onset ~ now at arm time, so earliest possible wake ~ now + floor_h.
  -- If the requested deadline lands before that, the safety floor WILL override it (silent ~defer).
  -- Surface it so a real "up by X" (flight/train) isn't quietly missed.
  IF p_latest_wake IS NOT NULL THEN
    v_floor_reach := now() + (floor_h || ' hours')::interval;
    v_below_floor := p_latest_wake < v_floor_reach;
  END IF;

  INSERT INTO smart_wake_sessions(
    user_id, armed_at, latest_wake_at, prep_min,
    target_h, base_h, d_debt, d_strain, d_quality, d_circadian, status)
  VALUES (p_user_id, now(), p_latest_wake, p_prep_min,
    v_target, v_base, v_dd, v_ds, v_dq, v_dc, 'armed')
  RETURNING id INTO sid;

  IF p_latest_wake IS NOT NULL THEN
    dl_label := to_char(p_latest_wake AT TIME ZONE tz, 'HH24:MI');
    IF v_below_floor THEN
      note := 'Heads up: ' || dl_label || ' is sooner than my ' || floor_h || 'h minimum-sleep floor from when '
           || 'you''d fall asleep, so if you need to be up that early for something real, set a normal alarm too. '
           || 'Otherwise I''ll wake you as close to ' || dl_label || ' as I safely can, protecting the ' || floor_h
           || 'h floor first.';
    ELSE
      note := 'You need about ' || v_target || 'h tonight. I''ll start the clock the moment you actually fall '
           || 'asleep — not now — hold a hard floor of ' || floor_h || 'h so I never wake you short, then catch a '
           || 'light-sleep window near your ' || v_target || 'h target. Earlier only if you''ve genuinely banked the '
           || 'recovery. You''re up by ' || dl_label || ' no matter what.';
    END IF;
  ELSE
    note := 'You need about ' || v_target || 'h tonight. I''ll start the clock the moment you actually fall '
         || 'asleep — not now — hold a hard floor of ' || floor_h || 'h so I never wake you short, then catch a '
         || 'light-sleep window near your ' || v_target || 'h target. Earlier only if you''ve genuinely banked the '
         || 'recovery. No deadline set, so I''ll make sure you''re up by ~9.5h at the very latest.';
  END IF;

  RETURN jsonb_build_object(
    'session_id', sid,
    'status', 'armed',
    'target_h', v_target,
    'base_h', v_base,
    'components', jsonb_build_object('debt',v_dd,'strain',v_ds,'quality',v_dq,'circadian',v_dc),
    'safety_floor_h', floor_h,
    'latest_wake_at', CASE WHEN p_latest_wake IS NULL THEN NULL
                           ELSE to_char(p_latest_wake AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
    'latest_wake_label', dl_label,
    'deadline_below_floor', v_below_floor,
    'prep_min', p_prep_min,
    'note', note,
    'need_breakdown', v_note
  );
END;$function$;

CREATE OR REPLACE FUNCTION public.cancel_smart_wake(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE n int;
BEGIN
  UPDATE smart_wake_sessions
     SET status='cancelled', updated_at=now()
   WHERE user_id=p_user_id AND status IN ('armed','asleep','ready');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('cancelled', n, 'status','cancelled');
END;$function$;


-- ============ 5. smart_wake_evaluate (state machine) ============
CREATE OR REPLACE FUNCTION public.smart_wake_evaluate(
  p_user_id uuid,
  p_now timestamptz DEFAULT now()
)
RETURNS TABLE(
  session_id uuid, should_fire boolean, reason text, stage text, wake_score integer,
  deep_prob numeric, slept_h_so_far numeric, target_h numeric,
  earliest_wake_at timestamptz, target_wake_at timestamptz, backstop_at timestamptz,
  recovery_pct numeric, status text
)
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
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

  -- ---- Onset detection / transition ----
  IF v_onset IS NULL THEN
    v_onset := detect_live_sleep_onset(p_user_id, s.armed_at, p_now);
    IF v_onset IS NOT NULL THEN
      floor_h       := GREATEST(6.0, 0.7 * v_target);
      v_earliest    := v_onset + make_interval(mins => round(floor_h*60)::int);
      v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int);
      v_backstop    := COALESCE(s.latest_wake_at, v_onset + interval '9.5 hours');
      UPDATE smart_wake_sessions
         SET status='asleep', sleep_onset_at=v_onset,
             earliest_wake_at=v_earliest, target_wake_at=v_target_wake,
             backstop_at=v_backstop, updated_at=now()
       WHERE id=s.id;
    ELSE
      -- no onset yet: honour a hard deadline, else wait, else expire stale.
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
    floor_h       := GREATEST(6.0, 0.7 * v_target);
    IF v_earliest IS NULL THEN v_earliest := v_onset + make_interval(mins => round(floor_h*60)::int); END IF;
    IF v_target_wake IS NULL THEN v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int); END IF;
    IF v_backstop IS NULL THEN v_backstop := COALESCE(s.latest_wake_at, v_onset + interval '9.5 hours'); END IF;
  END IF;

  v_slept := round(EXTRACT(epoch FROM (p_now - v_onset))/3600.0, 2);

  -- ---- Stage oracle (REUSE should_wake_now: enforces no-deep + light persistence) ----
  SELECT w.wake, w.wake_score, w.deep_prob, w.reason
    INTO sw_wake, sw_score, sw_dp, sw_reason
  FROM should_wake_now(p_user_id, v_earliest, v_backstop, p_now) w;

  v_stage := CASE WHEN sw_dp IS NULL THEN 'unknown'
                  WHEN sw_dp >= 0.40 THEN 'deep'
                  ELSE 'light_rem' END;

  -- ---- Recovery signals ----
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
  -- "exceptionally well recovered" = deep banked ABOVE his norm AND full HRV rebound.
  recovery_complete := total_deep_min >= 100 AND hrv_rebound;

  v_recpct := round(100 * (
        0.40 * LEAST(1.0, v_slept / NULLIF(v_target,0))
      + 0.35 * LEAST(1.0, total_deep_min / 100.0)
      + 0.25 * LEAST(1.0, COALESCE(recent_hrv,0) / NULLIF(base_hrv,0))
    ));

  -- ---- Decision ----
  IF p_now < v_earliest THEN
    v_should := false; v_reason := 'safety_floor';                 -- HARD: never before floor
  ELSIF p_now >= v_backstop THEN
    v_should := true;  v_reason := 'backstop_reached';             -- humane deadline: fire regardless
  ELSIF sw_wake IS TRUE THEN                                       -- light sustained, not deep
    IF recovery_complete THEN
      v_should := true;  v_reason := 'recovered_early';
    ELSIF p_now >= v_target_wake THEN
      v_should := true;  v_reason := 'target_reached';
    ELSIF p_now >= v_backstop - interval '20 minutes' THEN
      v_should := true;  v_reason := 'near_backstop_light';
    ELSE
      v_should := false; v_reason := 'light_hold_for_target';
    END IF;
  ELSE                                                             -- deep / unsustained / no data
    IF sw_dp IS NULL THEN v_should := false; v_reason := 'no_live_data_hold';
    ELSE v_should := false; v_reason := 'deep_hold'; END IF;
  END IF;

  session_id := s.id; should_fire := v_should; reason := v_reason;
  stage := v_stage; wake_score := sw_score; deep_prob := sw_dp;
  slept_h_so_far := v_slept; target_h := v_target;
  earliest_wake_at := v_earliest; target_wake_at := v_target_wake; backstop_at := v_backstop;
  recovery_pct := v_recpct;
  status := CASE WHEN v_should THEN 'ready' ELSE COALESCE(s.status,'asleep') END;
  RETURN NEXT;
END;$function$;


-- ============ 6. smart_wake_status + smart_wake_cron ============
-- ============ smart_wake_status: read RPC for the app UI ============
CREATE OR REPLACE FUNCTION public.smart_wake_status(
  p_user_id uuid,
  p_now timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s record; tz text := 'Europe/Berlin'; dp numeric; stg text;
  asleep_h numeric; earliest_in int; fresh boolean; last_s timestamptz; win text;
BEGIN
  SELECT * INTO s FROM smart_wake_sessions
   WHERE user_id=p_user_id AND smart_wake_sessions.status IN ('armed','asleep','ready')
   ORDER BY armed_at DESC LIMIT 1;

  IF s.id IS NULL THEN
    RETURN jsonb_build_object('armed', false, 'status', 'idle',
      'note', 'No smart wake armed. Tap "wake me at the perfect time" before bed.');
  END IF;

  SELECT max(recorded_at) INTO last_s FROM realtime_health WHERE user_id=p_user_id;
  fresh := last_s IS NOT NULL AND last_s >= p_now - interval '15 minutes';

  IF s.sleep_onset_at IS NULL THEN
    RETURN jsonb_build_object(
      'armed', true, 'status', s.status, 'session_id', s.id,
      'target_h', s.target_h,
      'latest_wake_label', CASE WHEN s.latest_wake_at IS NULL THEN NULL ELSE to_char(s.latest_wake_at AT TIME ZONE tz,'HH24:MI') END,
      'strap_streaming', fresh,
      'note', 'Armed and watching. I''ll start your ' || s.target_h || 'h clock the moment you actually fall asleep.');
  END IF;

  asleep_h   := round(EXTRACT(epoch FROM (p_now - s.sleep_onset_at))/3600.0, 2);
  earliest_in := CASE WHEN s.earliest_wake_at IS NULL THEN NULL
                      ELSE round(EXTRACT(epoch FROM (s.earliest_wake_at - p_now))/60.0)::int END;
  dp  := current_deep_probability(p_user_id, p_now);
  stg := CASE WHEN dp IS NULL THEN 'no_signal' WHEN dp >= 0.40 THEN 'deep' ELSE 'light_rem' END;
  win := to_char(s.earliest_wake_at AT TIME ZONE tz,'HH24:MI') || '–' || to_char(s.backstop_at AT TIME ZONE tz,'HH24:MI');

  RETURN jsonb_build_object(
    'armed', true, 'status', s.status, 'session_id', s.id,
    'target_h', s.target_h,
    'onset_label', to_char(s.sleep_onset_at AT TIME ZONE tz,'HH24:MI'),
    'asleep_h', asleep_h,
    'earliest_wake_label', to_char(s.earliest_wake_at AT TIME ZONE tz,'HH24:MI'),
    'earliest_in_min', earliest_in,
    'target_wake_label', to_char(s.target_wake_at AT TIME ZONE tz,'HH24:MI'),
    'backstop_label', to_char(s.backstop_at AT TIME ZONE tz,'HH24:MI'),
    'projected_window', win,
    'current_stage', stg, 'current_deep_prob', dp,
    'strap_streaming', fresh,
    'note', CASE
      WHEN earliest_in > 0 THEN 'Asleep ' || asleep_h || 'h. Holding a hard floor until ' || to_char(s.earliest_wake_at AT TIME ZONE tz,'HH24:MI') || ' — earliest I''d ever wake you. Then I watch for a light-sleep window through ' || to_char(s.backstop_at AT TIME ZONE tz,'HH24:MI') || '.'
      ELSE 'Asleep ' || asleep_h || 'h — past your floor. Watching for the next light-sleep window to wake you gently (by ' || to_char(s.backstop_at AT TIME ZONE tz,'HH24:MI') || ' at the latest).'
    END);
END;$function$;

-- ============ smart_wake_cron: the every-2-min driver ============
CREATE OR REPLACE FUNCTION public.smart_wake_cron(p_now timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql
VOLATILE SECURITY DEFINER
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
      -- calm-voice payload per reason
      IF ev.reason IN ('recovered_early') THEN
        v_title := '☀️ Perfect wake window';
        v_body  := 'You banked what you needed — HRV''s back up and you''re in light sleep at '||ev.slept_h_so_far||'h. This is the clean exit. Up you get.';
      ELSIF ev.reason = 'target_reached' THEN
        v_title := '☀️ Right on target';
        v_body  := 'You''ve hit your '||ev.target_h||'h and you''re in light sleep — the smoothest moment to wake. Morning.';
      ELSIF ev.reason = 'near_backstop_light' THEN
        v_title := '☀️ Catching your light window';
        v_body  := 'Close to your latest time and you just surfaced into light sleep — grabbing it now so you wake gentle.';
      ELSE  -- backstop_reached / deadline_no_onset
        v_title := '⏰ Time to wake';
        v_body  := 'This is your hard limit — up you get. Couldn''t find a lighter window in time, but you''re at '||COALESCE(ev.slept_h_so_far::text,'your deadline')||'h.';
      END IF;

      UPDATE smart_wake_sessions
         SET status='fired', fired_at=p_now, fired_reason=ev.reason,
             fired_stage=ev.stage, wake_score=ev.wake_score, recovery_pct=ev.recovery_pct,
             updated_at=now()
       WHERE id=ev.session_id;

      v_ctx := jsonb_build_object(
          'kind','smart_wake', 'priority','critical', 'alarm', true, 'session_id', ev.session_id,
          'reason', ev.reason, 'stage', ev.stage, 'wake_score', ev.wake_score,
          'slept_h', ev.slept_h_so_far, 'target_h', ev.target_h, 'recovery_pct', ev.recovery_pct);

      -- (1) history/audit row (notification_queue is NOT read by iOS)
      INSERT INTO notification_queue(user_id, type, scheduled_for, sent_at, title, body, context_data)
      VALUES (u, 'smart_wake', p_now, NULL, v_title, v_body, v_ctx);

      -- (2) DELIVERY row — the iOS NotificationListener polls `nudges`
      -- (channels @> {push} AND deliver_at recent). priority='alarm' + metadata.kind='smart_wake'
      -- tells the client to escalate to the strap-buzz smart-alarm actuator, not a passive banner.
      -- source/related_type constrained to 'health' (allowed set); discriminator lives in metadata.
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
END;$function$;


-- ============ 7. pg_cron schedules ============
-- Evaluator: every 2 min, drives smart_wake_cron for any armed/asleep session.
DO $mig$ BEGIN PERFORM cron.unschedule('smart_wake_evaluate_2min'); EXCEPTION WHEN OTHERS THEN NULL; END $mig$;
SELECT cron.schedule('smart_wake_evaluate_2min', '*/2 * * * *', $cj$SELECT public.smart_wake_cron();$cj$);

-- Daily pre-stage (optional / observability): pre-warm tonight's target at 17:00.
DO $mig$ BEGIN PERFORM cron.unschedule('smart_wake_prestage_daily'); EXCEPTION WHEN OTHERS THEN NULL; END $mig$;
SELECT cron.schedule('smart_wake_prestage_daily', '0 17 * * *', $cj$SELECT public.compute_sleep_need('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);$cj$);
