-- migration v112_smart_wakeup.sql
-- Smart Alarm — Module 3: the smart wake-up (stage reader + grogginess guard).
--
-- Source: deep-research 2026-06-04 (kb 3599a20f), Domains 1 + 2. Decides, live,
-- whether NOW is a good moment to wake: high when light/REM (easy wake), low
-- when deep (would cause inertia/grogginess). Personalized via the v110 spine
-- (his own resting-HR floor anchors "how deep is deep").
--
-- current_deep_probability: 0..1, blends the existing sleep_stage label with
-- HR-near-his-floor + HR-flatness (deep sleep = HR at floor, very flat).
-- should_wake_now: the alarm polls this each minute inside the wake window;
-- fires at the first non-deep moment, or at the hard deadline.

CREATE OR REPLACE FUNCTION public.current_deep_probability(
  p_user_id uuid, p_at timestamptz DEFAULT now()
)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE
  v_floor numeric; v_hr numeric; v_hrsd numeric; v_stage_deep numeric;
  hr_low numeric; flat numeric; dp numeric;
BEGIN
  SELECT median INTO v_floor FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  v_floor := COALESCE(v_floor, 52);

  SELECT avg(heart_rate), stddev_samp(heart_rate),
         avg(CASE WHEN sleep_stage='deep' THEN 1.0 ELSE 0.0 END)
    INTO v_hr, v_hrsd, v_stage_deep
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate>30
    AND recorded_at >= p_at - interval '5 minutes' AND recorded_at <= p_at;

  IF v_hr IS NULL THEN RETURN NULL; END IF;

  -- HR-near-his-floor is the reliable deep-sleep marker; the existing
  -- sleep_stage label is noisy, so it only lightly confirms.
  hr_low := LEAST(GREATEST((v_floor + 10 - v_hr) / 10.0, 0), 1);   -- 1 at floor, 0 at floor+10
  flat   := LEAST(GREATEST((4 - COALESCE(v_hrsd,4)) / 4.0, 0), 1); -- deep HR is very flat (sd<~2)
  dp     := 0.7*hr_low + 0.15*flat + 0.15*COALESCE(v_stage_deep,0);
  RETURN ROUND(LEAST(GREATEST(dp,0),1), 3);
END;$f$;

CREATE OR REPLACE FUNCTION public.should_wake_now(
  p_user_id uuid, p_win_start timestamptz, p_win_end timestamptz, p_at timestamptz DEFAULT now()
)
RETURNS TABLE(wake boolean, wake_score int, deep_prob numeric, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE dp numeric;
BEGIN
  dp := current_deep_probability(p_user_id, p_at);
  deep_prob := dp;
  wake_score := CASE WHEN dp IS NULL THEN NULL ELSE ROUND(100*(1-dp)) END;

  IF p_at >= p_win_end THEN
    wake := true;  reason := '⏰ deadline reached — waking now';
  ELSIF p_at < p_win_start THEN
    wake := false; reason := 'before wake window';
  ELSIF dp IS NULL THEN
    wake := false; reason := 'no live data';
  ELSIF dp < 0.40 THEN
    wake := true;  reason := '🟢 light sleep — ideal moment to wake';
  ELSE
    wake := false; reason := '🛑 deep sleep — hold, recheck shortly';
  END IF;
  RETURN NEXT;
END;$f$;

COMMENT ON FUNCTION public.should_wake_now IS
'v112 smart-alarm Module 3: poll each minute inside the wake window; fires at the first non-deep (deep_prob<0.4) moment, else at the hard deadline. deep_prob blends sleep_stage label + HR-near-personal-floor + HR-flatness.';
