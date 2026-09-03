-- migration v111_winddown_coach.sql
--
-- Smart Alarm — Module 2: the wind-down coach (Sleep Readiness Index).
--
-- Answers, live, from the evening stream: "is Fabi's body actually calm enough
-- to sleep yet, and if not, how far off?" This is the lever the failed-experiment
-- nights exposed — timing the wake is worthless if he went to bed wired.
--
-- Source: deep-research 2026-06-04 (knowledge_entries 3599a20f), Domain 4.
-- The textbook-best onset predictor is the distal-proximal skin-temp gradient
-- (DPG), which needs TWO temp sites; we have one `skin_temp`, so per the report
-- we fall back to the next-strongest signals, re-weighted: heart-rate-above-
-- sleep-baseline (dominant — what we literally watched fail: HR 80-100 at
-- bedtime), plus HRV rise and respiration drop as confirmations.
--
-- Everything normalizes against his OWN spine baselines (v110): his sleeping HR
-- floor (resting_hr median) anchors the readiness zone. resp=24 is the known
-- "could-not-estimate" sentinel and is excluded.
--
-- Returns a 0-100 readiness score, a ready flag, an ETA-to-ready, and a plain
-- message the app shows ("Heart's 18 above your sleep zone, ~15 min to ready").

CREATE OR REPLACE FUNCTION public.compute_sleep_readiness(
  p_user_id uuid,
  p_at timestamptz DEFAULT now()
)
RETURNS TABLE(
  sri int, hr_now numeric, hr_floor numeric, hr_gap numeric,
  rmssd_now numeric, resp_now numeric, ready boolean, eta_min int,
  status text, message text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_floor numeric;
  v_hr numeric; v_rmssd numeric; v_resp numeric;
  hr_ready numeric; hrv_ready numeric; resp_ready numeric;
  v_sri int; v_eta int; v_descent numeric;
  ready_hr numeric;   -- HR considered "in the sleep zone" (floor + 12)
  wired_hr numeric;   -- HR considered "fully wired"      (floor + 30)
  v_secondary numeric;
BEGIN
  -- 1. Personal sleeping-HR floor from the spine (30d, fallback 90d, fallback 52)
  SELECT median INTO v_floor FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  IF v_floor IS NULL THEN
    SELECT median INTO v_floor FROM personal_baselines
     WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=90 AND n_obs>=3;
  END IF;
  v_floor := COALESCE(v_floor, 52);
  ready_hr := v_floor + 12;
  wired_hr := v_floor + 30;

  -- 2. Personal descent rate (bpm/min) if learned, else research default 0.1
  SELECT mu INTO v_descent FROM personal_priors
   WHERE user_id=p_user_id AND param='hr_descent_rate';
  v_descent := GREATEST(COALESCE(v_descent, 0.1), 0.02);

  -- 3. Live evening state: last 10 min before p_at (resp=24 sentinel excluded)
  SELECT avg(heart_rate),
         avg(hrv_rmssd) FILTER (WHERE hrv_rmssd > 0),
         avg(respiratory_rate) FILTER (WHERE respiratory_rate > 0 AND respiratory_rate < 24)
    INTO v_hr, v_rmssd, v_resp
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate > 30
    AND recorded_at >= p_at - interval '10 minutes' AND recorded_at <= p_at;

  IF v_hr IS NULL THEN
    sri:=NULL; hr_now:=NULL; hr_floor:=v_floor; hr_gap:=NULL; rmssd_now:=NULL; resp_now:=NULL;
    ready:=NULL; eta_min:=NULL; status:='⚪ no data'; message:='No recent strap data to read.';
    RETURN NEXT; RETURN;
  END IF;

  -- 4. Component readiness fractions (0..1), neutral 0.5 when a signal is missing
  hr_ready   := LEAST(GREATEST((wired_hr - v_hr) / (wired_hr - ready_hr), 0), 1);
  hrv_ready  := CASE WHEN v_rmssd IS NULL THEN 0.5
                     ELSE LEAST(GREATEST((v_rmssd - 30) / 20.0, 0), 1) END;  -- 30 aroused, 50 parasympathetic
  resp_ready := CASE WHEN v_resp IS NULL THEN 0.5
                     ELSE LEAST(GREATEST((23 - v_resp) / 4.0, 0), 1) END;    -- 23 awake, 19 drowsy

  -- 5. SRI with HR as a HARD GATE. HRV/respiration estimates are unreliable
  --    during arousal (motion artifacts read fake-calm), so they can only
  --    refine readiness once the heart is already coming down — never override
  --    a high HR. sri = hr_ready * (0.7 + 0.3*secondary).
  v_secondary := 0.56*hrv_ready + 0.44*resp_ready;
  v_sri := ROUND(100 * hr_ready * (0.7 + 0.3*v_secondary));

  -- 6. ETA to ready (minutes of wind-down still needed)
  IF v_hr <= ready_hr THEN v_eta := 0;
  ELSE v_eta := LEAST(CEIL((v_hr - ready_hr) / v_descent), 120); END IF;

  sri:=v_sri; hr_now:=ROUND(v_hr,1); hr_floor:=v_floor; hr_gap:=ROUND(v_hr - v_floor,1);
  rmssd_now:=ROUND(v_rmssd,1); resp_now:=ROUND(v_resp,1); eta_min:=v_eta;
  ready := v_sri >= 70;

  IF v_sri >= 70 THEN
    status := '🟢 ready';
    message := 'Your body is calm. Good window to fall asleep.';
  ELSIF v_sri >= 40 THEN
    status := '🟡 getting there';
    message := format('Heart''s %s bpm above your sleep zone. ~%s min to ready.',
                      ROUND(v_hr - ready_hr), v_eta);
  ELSE
    status := '🔴 wired';
    message := format('Still wired (HR %s, your sleep zone is ~%s). About %s min of wind-down.',
                      ROUND(v_hr), ROUND(ready_hr), v_eta);
  END IF;
  RETURN NEXT;
END;
$function$;

COMMENT ON FUNCTION public.compute_sleep_readiness IS
'v111 smart-alarm Module 2: live Sleep Readiness Index (0-100) from last 10 min of stream vs personal spine baselines. HR-above-sleep-floor dominant (0.55) + HRV rise (0.25) + respiration drop (0.20); DPG omitted (single temp sensor). Returns ready flag + ETA-to-ready + plain coaching message. resp=24 sentinel excluded. Sleep zone = resting_hr floor +12bpm.';
