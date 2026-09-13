-- v183 — the sleep stager stops lying, and two of the four sleep-need channels
--        start carrying information again.
--
-- 2026-09-06. Four separate things were wrong, and they compounded into
-- "the smart alarm never feels smart":
--
-- 1. realtime_health.sleep_stage is an on-device latching label. Measured against
--    the nightly rollup over five real nights it calls 38-62% of the night deep
--    (rollup: ~19%), 1-6% REM (rollup: ~21%), and ~2.5x too much of it awake.
--    Everything downstream trusted it.
--
-- 2. should_wake_now suppressed the alarm whenever a majority of the last five
--    minutes were LABELLED awake (v174). Because the label over-calls awake, that
--    veto tripped on ordinary nights, the smart branch never ran, and every wake
--    fell through to the backstop.
--
-- 3. compute_sleep_need.d_debt was LEAST(0.75, 0.25*debt) — it pins at the cap for
--    any debt past 3h, and his debt is essentially always past 3h. It has been a
--    constant +0.75 in 19 of 23 armed sessions. A constant is not a signal.
--
-- 4. compute_sleep_need.d_circadian read health_metrics.sleep_consistency_pct,
--    NULL on 100% of rows for 90 days, so it was always exactly 0 — while
--    sleep_consistency_score() sat right there returning a real number (41).
--
-- Plus the structural one: an inflated target pushes target_wake_at past the
-- deadline, which collapses the light-sleep search window to the final 20 minutes.
--
-- No motion signal exists to help: movement_score and accel_mag_mg are 100% NULL
-- in realtime_health overnight. This is heart rate and RMSSD only, and REM/light
-- separation is correspondingly soft. Deep-vs-rest is the discrimination the alarm
-- actually needs and that one holds up.
--
-- Validated by replaying five real nights (2026-08-27, 08-30, 09-01, 09-04, 09-06)
-- minute by minute:  deep 12-26% (rollup 14-19%), REM 3-18% (rollup 17-26%),
-- against the on-device label's deep 38-62% / REM 1-6%.

-- ═══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.ramp01(x numeric, lo numeric, hi numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$ SELECT CASE WHEN x IS NULL OR hi <= lo THEN NULL
                ELSE LEAST(1.0, GREATEST(0.0, (x - lo) / (hi - lo))) END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- ── live_sleep_stage v2: HR/HRV stager, anchored to the night's OWN distribution ──
-- v1 used personal_baselines.resting_hr (51) as the deep-sleep anchor and called 63%
-- of the night deep. That baseline is the *reported morning RHR*, not the sleeping
-- floor: his HR sits within ~3 bpm of it for most of the night, so "near the floor"
-- was true almost always. Staging is inherently relative WITHIN a night, so the
-- anchor is now the night-so-far 5th percentile with the night's own IQR as scale.
-- No motion input exists: movement_score and accel_mag_mg are 100% NULL overnight.
CREATE OR REPLACE FUNCTION public.live_sleep_stage(
  p_user_id uuid,
  p_at      timestamptz DEFAULT now(),
  p_win_min int         DEFAULT 5,
  p_since   timestamptz DEFAULT NULL)
RETURNS TABLE(stage text, p_awake numeric, p_deep numeric, p_rem numeric, p_light numeric,
              hr numeric, hr_pos numeric, hr_sd numeric, rmssd_rel numeric, n_min int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  since timestamptz; n_p05 numeric; n_p60 numeric; n_rm numeric; n_hist int;
  v_hr numeric; v_sd numeric; v_rm numeric; v_n int;
  pos numeric; rmr numeric; scale numeric;
  a numeric; d numeric; r numeric; l numeric := 0.62; tot numeric;
BEGIN
  -- The reference distribution must be THIS night, not the last ten hours: reaching
  -- back into waking hours inflates the spread and makes every sleeping minute look
  -- like it is sitting on the floor. Prefer the armed session's detected onset.
  IF p_since IS NULL THEN
    SELECT sleep_onset_at INTO since FROM smart_wake_sessions
     WHERE user_id=p_user_id AND sleep_onset_at IS NOT NULL AND sleep_onset_at <= p_at
     ORDER BY armed_at DESC LIMIT 1;
    IF since IS NULL THEN
      SELECT sleep_start INTO since FROM health_metrics
       WHERE user_id=p_user_id AND sleep_start IS NOT NULL AND sleep_start <= p_at
       ORDER BY metric_date DESC LIMIT 1;
    END IF;
  ELSE
    since := p_since;
  END IF;
  since := GREATEST(COALESCE(since, p_at - interval '8 hours'), p_at - interval '11 hours');

  -- The night so far: floor, working spread, and typical vagal tone.
  SELECT count(*),
         percentile_cont(0.05) WITHIN GROUP (ORDER BY m_hr),
         percentile_cont(0.60) WITHIN GROUP (ORDER BY m_hr),
         percentile_cont(0.50) WITHIN GROUP (ORDER BY m_rm)
    INTO n_hist, n_p05, n_p60, n_rm
  FROM (
    SELECT date_trunc('minute', recorded_at) mi,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY heart_rate) m_hr,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_rmssd) FILTER (WHERE hrv_rmssd > 0) m_rm
    FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate > 25
      AND recorded_at > since AND recorded_at <= p_at
    GROUP BY 1
  ) h;

  -- Cold start (first hour of a night): fall back to his global floor.
  IF COALESCE(n_hist,0) < 60 OR n_p05 IS NULL THEN
    SELECT COALESCE(median, 52) INTO n_p05 FROM personal_baselines
     WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
    n_p05 := COALESCE(n_p05, 52); n_p60 := n_p05 + 4.5;
    SELECT COALESCE(NULLIF(median,0), 46) INTO n_rm FROM personal_baselines
     WHERE user_id=p_user_id AND metric='hrv_avg' AND window_days=30 AND n_obs>=3;
  END IF;
  n_rm  := GREATEST(COALESCE(n_rm, 46), 20);
  scale := GREATEST(3.0, COALESCE(n_p60,n_p05+4.5) - n_p05);

  -- The decision window itself, at minute resolution.
  SELECT avg(m_hr), stddev_samp(m_hr), avg(m_rm), count(*)
    INTO v_hr, v_sd, v_rm, v_n
  FROM (
    SELECT date_trunc('minute', recorded_at) mi,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY heart_rate) m_hr,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_rmssd) FILTER (WHERE hrv_rmssd > 0) m_rm
    FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate > 25
      AND recorded_at >  p_at - make_interval(mins => p_win_min)
      AND recorded_at <= p_at
    GROUP BY 1
  ) z;

  IF v_n IS NULL OR v_n < 2 OR v_hr IS NULL THEN
    stage:=NULL; p_awake:=NULL; p_deep:=NULL; p_rem:=NULL; p_light:=NULL;
    hr:=v_hr; hr_pos:=NULL; hr_sd:=v_sd; rmssd_rel:=NULL; n_min:=COALESCE(v_n,0);
    RETURN NEXT; RETURN;
  END IF;

  v_sd := COALESCE(v_sd, 0);
  pos  := (v_hr - n_p05) / scale;                       -- 0 at the night's floor, 1 at its 60th pct
  rmr  := CASE WHEN v_rm IS NULL THEN NULL ELSE v_rm / n_rm END;

  -- Deep / SWS: at the night's floor, metronome-flat, vagal tone at or above its own norm.
  d := 0.40 * ramp01(0.65 - pos, 0, 0.55)
     + 0.35 * ramp01(1.25 - v_sd, 0, 0.85)
     + 0.25 * COALESCE(ramp01(rmr, 0.95, 1.25), 0.35);

  -- REM: lifted off the floor and variable, but with HF vagal tone collapsing.
  -- Low RMSSD *while asleep* is what separates REM from deep; the modest HR lift
  -- is what separates it from being awake.
  r := 0.30 * ramp01(pos, 0.35, 1.10)
     + 0.25 * ramp01(v_sd, 0.9, 2.6)
     + 0.45 * COALESCE(ramp01(1.0 - rmr, -0.05, 0.30), 0.3);
  r := r * (1 - 0.75 * ramp01(pos, 2.2, 3.4));

  -- Awake: heart rate well clear of the night's floor, or swinging hard.
  a := 0.55 * ramp01(pos, 1.6, 3.0) + 0.45 * ramp01(v_sd, 2.8, 6.0);

  tot := a + d + r + l;
  p_awake := round(a/tot,3); p_deep := round(d/tot,3);
  p_rem := round(r/tot,3);   p_light := round(l/tot,3);
  stage := CASE greatest(a,d,r,l) WHEN a THEN 'awake' WHEN d THEN 'deep' WHEN r THEN 'rem' ELSE 'light' END;
  hr := round(v_hr,1); hr_pos := round(pos,3); hr_sd := round(v_sd,2);
  rmssd_rel := round(rmr,3); n_min := v_n;
  RETURN NEXT;
END;$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- ── current_deep_probability: off the latching column, onto the stager ────────
-- Was: 0.7*HR-near-floor + 0.15*flat + 0.15*sleep_stage='deep'. The floor it used
-- (personal_baselines.resting_hr) is the morning RHR, which his sleeping HR sits
-- within ~3 bpm of all night, so the dominant term was near-saturated; and the
-- label term reads the column that calls 1% of the night REM. Contract unchanged:
-- 0..1, and >= 0.40 still means "deep, do not wake".
CREATE OR REPLACE FUNCTION public.current_deep_probability(p_user_id uuid, p_at timestamptz DEFAULT now())
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
  SELECT s.p_deep FROM live_sleep_stage(p_user_id, p_at, 5) s
$function$;

-- ── should_wake_now: the awake test no longer trusts the latching column ─────
-- v174 suppressed the alarm when a majority of the last five minutes were LABELLED
-- awake. That column over-calls awake ~2.5x against the nightly rollup, so the
-- smart branch was being vetoed on most nights and every wake fell through to the
-- backstop — which is exactly what "the alarm feels broken" looked like. Now the
-- suppression needs the stager to agree at two timescales, and it is disabled
-- entirely inside the last 45 minutes before the deadline: near the end, being
-- wrong about "he's already up" costs him the morning.
CREATE OR REPLACE FUNCTION public.should_wake_now(
  p_user_id uuid, p_win_start timestamptz, p_win_end timestamptz, p_at timestamptz DEFAULT now())
RETURNS TABLE(wake boolean, wake_score integer, deep_prob numeric, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  s5 record; s15 record; dp numeric; dp_prev numeric; genuinely_awake boolean := false;
BEGIN
  SELECT * INTO s5  FROM live_sleep_stage(p_user_id, p_at, 5)  z;
  SELECT * INTO s15 FROM live_sleep_stage(p_user_id, p_at, 15) z;

  dp := s5.p_deep;
  deep_prob  := dp;
  wake_score := CASE WHEN dp IS NULL THEN NULL ELSE ROUND(100*(1-dp)) END;

  -- Both timescales must agree, and only while the deadline is still comfortably away.
  genuinely_awake := COALESCE(s5.p_awake, 0) >= 0.35
                 AND COALESCE(s15.p_awake, 0) >= 0.30
                 AND p_at < p_win_end - interval '45 minutes';

  IF p_at >= p_win_end THEN
    wake := true; wake_score := 100; deep_prob := NULL;
    reason := '⏰ deadline reached — waking now';
  ELSIF p_at < p_win_start THEN
    wake := false; reason := 'before wake window';
  ELSIF genuinely_awake THEN
    wake := false;
    reason := format('☀️ already awake (HR %s, %s above your floor) — no alarm needed',
                     round(s5.hr), round(s5.hr_pos,1));
  ELSIF dp IS NULL THEN
    wake := false; reason := 'no live data';
  ELSIF dp < 0.40 THEN
    -- Light read must PERSIST (also light ~3 min earlier) so one transient arousal
    -- coming out of deep sleep cannot force an early wake (finding #22).
    dp_prev := current_deep_probability(p_user_id, p_at - interval '3 minutes');
    IF dp_prev IS NOT NULL AND dp_prev < 0.40 THEN
      wake := true;  reason := format('🟢 %s sleep (sustained) — ideal moment to wake', COALESCE(s5.stage,'light'));
    ELSE
      wake := false; reason := '🟡 light but not yet sustained — hold, recheck shortly';
    END IF;
  ELSE
    wake := false; reason := '🛑 deep sleep — hold, recheck shortly';
  END IF;
  RETURN NEXT;
END;$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- ── compute_sleep_debt: don't let unobserved nights quietly erase debt ───────
-- The old one summed capped deficits over nights where sleep_hours > 0. Coverage
-- has run at 13 usable nights in 30, so on a bad week the sum silently measured
-- three nights and called it a week. Now the observed deficit is scaled up to the
-- full window, and a week with too little coverage returns NULL rather than a
-- confident zero.
CREATE OR REPLACE FUNCTION public.compute_sleep_debt(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE base numeric; debt numeric; nights int; win int := 7;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- v153 (finding #16): cap each night's deficit at 2h so one very short night
  -- cannot dominate and saturate the debt channel on noise.
  SELECT COALESCE(sum(LEAST(2, GREATEST(0, base - sleep_hours))), 0), count(*)
    INTO debt, nights
  FROM health_metrics
  WHERE user_id=p_user_id
    AND sleep_hours > 0
    AND sleep_complete IS NOT FALSE
    AND COALESCE(excluded, false) = false
    AND metric_date >= CURRENT_DATE - win AND metric_date < CURRENT_DATE;

  IF nights < 3 THEN RETURN NULL; END IF;          -- too little observed to claim a number
  RETURN ROUND(debt * (win::numeric / nights), 2); -- scale the observed nights up to the window
END;$function$;

-- ── compute_sleep_need: unpin the debt term, revive the circadian term ───────
-- Two channels were carrying no information at all:
--   d_debt      = LEAST(0.75, 0.25*debt). Anything past 3h of debt pinned it to the
--                 cap, and his debt is essentially always past 3h — so for months
--                 it was a constant +0.75 in 19 of 23 armed sessions.
--   d_circadian read health_metrics.sleep_consistency_pct, which has been NULL on
--                 100% of rows for 90 days. Always exactly 0. The real
--                 sleep_consistency_score() function existed the whole time.
-- The debt curve is now saturating-but-never-pinned, so more debt always means a
-- slightly higher target and the channel stays readable.
CREATE OR REPLACE FUNCTION public.compute_sleep_need(p_user_id uuid, p_date date DEFAULT (((now() AT TIME ZONE 'Europe/Berlin'::text))::date + 1))
RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_quality numeric, d_circadian numeric, debt_raw numeric, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  base numeric; debt numeric; dd numeric := 0; ds numeric := 0; dq numeric := 0; dc numeric := 0;
  ystrain numeric; strainbase numeric; yhrv numeric; hrvbase numeric;
  yeff numeric; ydeep numeric; ycons numeric; v_last date;
  deepnorm numeric := 105;
  parts text;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- Homeostatic debt: repayment is partial (~25%/night), and the curve saturates
  -- smoothly toward 0.75 instead of clipping there, so the term keeps discriminating
  -- between 4h owed and 14h owed.
  debt := compute_sleep_debt(p_user_id);
  IF debt IS NOT NULL THEN
    dd := round(0.75 * (1 - exp(-debt / 7.0)), 2);
  END IF;

  SELECT metric_date, strain_score, hrv_avg, sleep_efficiency_pct, deep_sleep_min
    INTO v_last, ystrain, yhrv, yeff, ydeep
    FROM health_metrics
   WHERE user_id=p_user_id AND sleep_hours > 0
   ORDER BY metric_date DESC LIMIT 1;

  -- Strain: yesterday's load vs his 14-day baseline. strain_score pegs at Whoop's
  -- 21.0 ceiling on ~46% of days, so this channel is weak by construction; the 0.4
  -- cap keeps a saturated input from dominating.
  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  IF ystrain IS NOT NULL AND strainbase > 0 AND ystrain > strainbase THEN
    ds := ds + LEAST(0.4, 0.4 * ((ystrain / strainbase) - 1));
  END IF;
  hrvbase := COALESCE(
    (SELECT baseline_hrv_avg FROM current_state WHERE user_id=p_user_id),
    (SELECT avg(hrv_avg) FROM health_metrics WHERE user_id=p_user_id AND hrv_avg>0 AND metric_date >= CURRENT_DATE - 14));
  IF yhrv IS NOT NULL AND hrvbase IS NOT NULL AND yhrv < 0.90 * hrvbase THEN ds := ds + 0.15; END IF;
  ds := round(LEAST(0.5, ds), 2);

  IF yeff  IS NOT NULL AND yeff  < 85            THEN dq := dq + LEAST(0.4, 0.4*((85-yeff)/15.0)); END IF;
  IF ydeep IS NOT NULL AND ydeep < deepnorm - 15 THEN dq := dq + 0.15; END IF;
  dq := round(LEAST(0.5, dq), 2);

  -- Circadian: measured off his actual bedtime scatter, not the dead column.
  ycons := sleep_consistency_score(p_user_id, (now() AT TIME ZONE 'Europe/Berlin')::date);
  IF ycons IS NOT NULL AND ycons < 70 THEN
    dc := round(LEAST(0.25, 0.25 * ((70 - ycons) / 40.0)), 2);
  END IF;

  target_h    := round(LEAST(9.5, GREATEST(6.0, base + dd + ds + dq + dc)), 2);
  base_h      := base;  d_debt := dd;  d_strain := ds;  d_quality := dq;  d_circadian := dc;
  debt_raw    := round(debt, 2);

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || dd || ' debt (' || round(debt,1) || 'h owed)'; END IF;
  IF ds > 0 THEN parts := parts || ' +' || ds || ' strain'; END IF;
  IF dq > 0 THEN parts := parts || ' +' || dq || ' quality'; END IF;
  IF dc > 0 THEN parts := parts || ' +' || dc || ' circadian (bedtime scatter)'; END IF;
  IF debt IS NULL THEN parts := parts || ' (debt unknown — too few observed nights)'; END IF;
  note := parts || ' -> aim for ' || target_h || 'h tonight';
  RETURN NEXT;
END;$function$;

-- ═══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.target_sleep_duration(p_user_id uuid, p_for_date date DEFAULT (((now() AT TIME ZONE 'Europe/Berlin'::text))::date + 1))
 RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_illness numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE base numeric; debt numeric; ystrain numeric; strainbase numeric;
        yrhr numeric; rhrmed numeric; yalc numeric; was_alcohol boolean;
        v_last date; dd numeric; ds numeric; di numeric; parts text;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- Debt: gentle. Repay over multiple nights at his sweet spot, not one big night.
  -- compute_sleep_debt now returns NULL when the week is too thinly observed to
  -- claim a number, so this must not propagate a NULL into target_h. Same
  -- saturating-but-never-pinned curve as compute_sleep_need, scaled to this 0.5 cap.
  debt := compute_sleep_debt(p_user_id);
  dd := CASE WHEN debt IS NULL THEN 0 ELSE round(0.5 * (1 - exp(-debt / 7.0)), 2) END;

  -- Read the MOST RECENT completed night (not CURRENT_DATE-1, which lags a day
  -- when the plan is computed in the evening after today's recompute). This is
  -- the bug that read the alcohol night's RHR instead of last night's recovered one.
  SELECT metric_date, resting_hr, strain_score, alcohol_impact
    INTO v_last, yrhr, ystrain, yalc
    FROM health_metrics
   WHERE user_id=p_user_id AND sleep_hours > 0
   ORDER BY metric_date DESC LIMIT 1;

  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  ds := CASE WHEN ystrain IS NOT NULL AND strainbase IS NOT NULL AND ystrain > strainbase*1.15
             THEN 0.3 ELSE 0 END;

  -- Was the most recent night an alcohol night? Then an elevated RHR is a
  -- hangover, not illness — do NOT prescribe extra sleep for it.
  was_alcohol := COALESCE(yalc,0) >= 1;
  IF NOT was_alcohol AND v_last IS NOT NULL THEN
    BEGIN
      was_alcohol := detect_overnight_alcohol(p_user_id, v_last, 'Europe/Berlin');
    EXCEPTION WHEN OTHERS THEN was_alcohol := false;
    END;
  END IF;

  SELECT median INTO rhrmed FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  di := CASE WHEN yrhr IS NOT NULL AND rhrmed IS NOT NULL AND yrhr > rhrmed + 3 AND NOT was_alcohol
             THEN 0.5 ELSE 0 END;

  -- Clamp tightened: never push him past base+0.75 — his data says oversleeping
  -- (circadian drift) makes him groggier, not more rested.
  target_h := ROUND(LEAST(GREATEST(base + dd + ds + di, base - 0.5), base + 0.75), 2);
  base_h := base; d_debt := ROUND(dd,2); d_strain := ds; d_illness := di;

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || round(dd,1) || ' debt'; END IF;
  IF ds > 0 THEN parts := parts || ' +0.3 high strain'; END IF;
  IF di > 0 THEN parts := parts || ' +0.5 illness signs'; END IF;
  IF was_alcohol AND yrhr IS NOT NULL AND rhrmed IS NOT NULL AND yrhr > rhrmed + 3 THEN
    parts := parts || ' (skipped illness bump — that was the alcohol)';
  END IF;
  note := parts || ' = aim for ' || target_h || 'h';
  RETURN NEXT;
END;$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- ── night_deep_minutes: deep-sleep total without the latching column ─────────
-- smart_wake_evaluate counted minutes labelled sleep_stage='deep', the column that
-- calls 38-62% of a night deep against the rollup's ~19%. One pass, night-relative,
-- same shape as live_sleep_stage's deep test.
CREATE OR REPLACE FUNCTION public.night_deep_minutes(p_user_id uuid, p_onset timestamptz, p_at timestamptz DEFAULT now())
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE n int;
BEGIN
  WITH m AS (
    SELECT date_trunc('minute', recorded_at) mi,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY heart_rate) hr
    FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate > 25 AND recorded_at > p_onset AND recorded_at <= p_at
    GROUP BY 1),
  r AS (
    SELECT mi, hr,
           avg(hr)         OVER (ORDER BY mi ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) hr5,
           stddev_samp(hr) OVER (ORDER BY mi ROWS BETWEEN 4 PRECEDING AND CURRENT ROW) sd5
    FROM m),
  s AS (
    SELECT percentile_cont(0.05) WITHIN GROUP (ORDER BY hr) p05,
           GREATEST(3.0, percentile_cont(0.60) WITHIN GROUP (ORDER BY hr)
                       - percentile_cont(0.05) WITHIN GROUP (ORDER BY hr)) scale
    FROM m)
  SELECT count(*) INTO n FROM r, s
   WHERE r.hr5 <= s.p05 + 0.65 * s.scale AND COALESCE(r.sd5, 0) < 1.25;
  RETURN COALESCE(n, 0);
END;$function$;

-- ═══════════════════════════════════════════════════════════════════════
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

  -- ---- Onset detection / transition ----
  IF v_onset IS NULL THEN
    v_onset := detect_live_sleep_onset(p_user_id, s.armed_at, p_now);
    IF v_onset IS NOT NULL THEN
      floor_h       := GREATEST(6.0, 0.7 * v_target);
      v_earliest    := v_onset + make_interval(mins => round(floor_h*60)::int);
      v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int);
      v_backstop    := COALESCE(s.latest_wake_at, v_onset + interval '9.5 hours');
      -- A target that lands past the deadline collapses the light-sleep search to
      -- the last 20 minutes (near_backstop_light) and every night ends on the
      -- backstop — which is what "the smart alarm never feels smart" was. Keep at
      -- least a 30-minute window to actually find a light-sleep moment in.
      v_target_wake := GREATEST(v_earliest, LEAST(v_target_wake, v_backstop - interval '30 minutes'));
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
    floor_h       := GREATEST(6.0, 0.7 * v_target);
    IF v_earliest IS NULL THEN v_earliest := v_onset + make_interval(mins => round(floor_h*60)::int); END IF;
    IF v_target_wake IS NULL THEN v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int); END IF;
    IF v_backstop IS NULL THEN v_backstop := COALESCE(s.latest_wake_at, v_onset + interval '9.5 hours'); END IF;
    v_target_wake := GREATEST(v_earliest, LEAST(v_target_wake, v_backstop - interval '30 minutes'));
  END IF;

  v_slept := round(EXTRACT(epoch FROM (p_now - v_onset))/3600.0, 2);

  -- ---- Stage oracle (REUSE should_wake_now: enforces no-deep + light persistence) ----
  SELECT w.wake, w.wake_score, w.deep_prob, w.reason
    INTO sw_wake, sw_score, sw_dp, sw_reason
  FROM should_wake_now(p_user_id, v_earliest, v_backstop, p_now) w;

  v_stage := CASE WHEN sw_dp IS NULL THEN 'unknown'
                  WHEN sw_dp >= 0.40 THEN 'deep'
                  ELSE 'light_rem' END;

  -- ---- Recovery signals (display/telemetry only now; NO LONGER gates an early fire) ----
  total_deep_min := night_deep_minutes(p_user_id, v_onset, p_now);

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
    v_should := false; v_reason := 'safety_floor';                 -- HARD: never before floor
  ELSIF p_now >= v_backstop THEN
    v_should := true;  v_reason := 'backstop_reached';             -- humane deadline: fire regardless
  ELSIF sw_wake IS TRUE THEN                                       -- light sustained, not deep
    -- v155: recovered_early can NO LONGER fire before target. His data has no recovery plateau,
    -- and its old evidence (total_deep_min) reads the broken sleep_stage column. Hold to target.
    IF p_now >= v_target_wake THEN
      v_should := true;  v_reason := CASE WHEN recovery_complete THEN 'recovered_early' ELSE 'target_reached' END;
    ELSIF p_now >= v_backstop - interval '20 minutes' THEN
      v_should := true;  v_reason := 'near_backstop_light';
    ELSE
      v_should := false; v_reason := 'light_hold_for_target';
    END IF;
  ELSE                                                             -- deep / unsustained / no data
    IF sw_dp IS NULL THEN v_should := false; v_reason := 'no_live_data_hold';
    ELSE v_should := false; v_reason := 'deep_hold'; END IF;
  END IF;

  IF s.target_wake_at IS DISTINCT FROM v_target_wake THEN
    UPDATE smart_wake_sessions SET target_wake_at=v_target_wake, updated_at=now() WHERE id=s.id;
  END IF;

  session_id := s.id; should_fire := v_should; reason := v_reason;
  stage := v_stage; wake_score := sw_score; deep_prob := sw_dp;
  slept_h_so_far := v_slept; target_h := v_target;
  earliest_wake_at := v_earliest; target_wake_at := v_target_wake; backstop_at := v_backstop;
  recovery_pct := v_recpct;
  status := CASE WHEN v_should THEN 'ready' ELSE COALESCE(s.status,'asleep') END;
  RETURN NEXT;
END;$function$;

-- ═══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.refresh_current_state_from_realtime()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_user UUID := NEW.user_id;
  v_now TIMESTAMPTZ := NEW.recorded_at;

  v_last_15m_start TIMESTAMPTZ := v_now - INTERVAL '15 minutes';
  v_last_1h_start  TIMESTAMPTZ := v_now - INTERVAL '1 hour';
  v_last_7d_start  TIMESTAMPTZ := v_now - INTERVAL '7 days';

  v_cog_15m NUMERIC;
  v_cog_label TEXT;
  v_illness_1h NUMERIC;
  v_baseline_hrv NUMERIC;
  v_baseline_rhr INTEGER;
  v_baseline_rr NUMERIC;

  -- normalised copies: current_state carries CHECK constraints that
  -- realtime_health does not, so out-of-set values become NULL, never fatal
  v_stage TEXT;
  v_readiness TEXT;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.current_state
    WHERE user_id = v_user AND updated_at > v_now - INTERVAL '5 seconds'
  ) THEN
    RETURN NEW;
  END IF;

  -- v183: the on-device label calls ~2.5x more of the night 'awake' than the nightly
  -- rollup does (274-472 min vs 76-121), which is what made the app say "awake" for
  -- long stretches of an ordinary night. Keep the awake call only when the heart rate
  -- actually agrees; otherwise it is light sleep. Everything else passes through.
  v_stage := CASE lower(coalesce(NEW.sleep_stage, ''))
               WHEN 'awake'     THEN
                 CASE WHEN NEW.heart_rate IS NULL
                        OR NEW.heart_rate >= COALESCE(
                             (SELECT baseline_resting_hr + 10 FROM public.current_state WHERE user_id = v_user), 62)
                      THEN 'awake' ELSE 'light' END
               WHEN 'light'     THEN 'light'
               WHEN 'deep'      THEN 'deep'
               WHEN 'rem'       THEN 'rem'
               WHEN 'light_rem' THEN 'light'
               WHEN 'sws'       THEN 'deep'
               ELSE NULL
             END;

  v_readiness := CASE lower(coalesce(NEW.readiness, ''))
                   WHEN 'green'  THEN 'green'
                   WHEN 'yellow' THEN 'yellow'
                   WHEN 'red'    THEN 'red'
                   ELSE NULL
                 END;

  SELECT AVG(cognitive_capacity) INTO v_cog_15m
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_15m_start
    AND cognitive_capacity IS NOT NULL AND cognitive_capacity > 0;

  SELECT cognitive_label INTO v_cog_label
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_15m_start
    AND cognitive_label IS NOT NULL
  GROUP BY cognitive_label ORDER BY COUNT(*) DESC LIMIT 1;

  IF v_cog_label IS NOT NULL AND v_cog_label NOT IN ('Full','Good','Reduced','Low') THEN
    v_cog_label := NULL;
  END IF;

  SELECT MAX(illness_risk) INTO v_illness_1h
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_1h_start
    AND illness_risk IS NOT NULL;

  -- audit #38: resting HR is the LOW of sleeping HR, not its average.
  SELECT AVG(hrv_rmssd),
         (percentile_cont(0.05) WITHIN GROUP (ORDER BY heart_rate))::INTEGER,
         AVG(respiratory_rate)
  INTO v_baseline_hrv, v_baseline_rhr, v_baseline_rr
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_7d_start
    AND sleep_stage IN ('deep','rem','light')
    AND hrv_rmssd IS NOT NULL AND hrv_rmssd > 0;

  INSERT INTO public.current_state (
    user_id, updated_at,
    strap_connected, last_ble_sample_at, battery_pct,
    current_hr, current_hrv_rmssd, current_sdnn, current_dfa_alpha1, current_respiratory_rate,
    current_cognitive_capacity, current_cognitive_label, current_readiness,
    current_illness_risk, current_sleep_stage,
    current_hmm_state, current_hmm_state_id,
    baseline_hrv_avg, baseline_resting_hr, baseline_respiratory_rate,
    current_activity_state
  ) VALUES (
    v_user, v_now,
    TRUE, v_now, NEW.battery_pct,
    NEW.heart_rate, NEW.hrv_rmssd, NEW.sdnn, NEW.dfa_alpha1, NEW.respiratory_rate,
    v_cog_15m::INTEGER, v_cog_label, v_readiness,
    v_illness_1h, v_stage,
    NEW.hmm_state, NEW.hmm_state_id,
    v_baseline_hrv, v_baseline_rhr, v_baseline_rr,
    CASE
      WHEN v_stage IN ('deep','rem','light') THEN 'sleeping'
      WHEN NEW.heart_rate > 110 THEN 'active'
      ELSE 'resting'
    END
  )
  ON CONFLICT (user_id) DO UPDATE SET
    updated_at = EXCLUDED.updated_at,
    strap_connected = TRUE,
    last_ble_sample_at = EXCLUDED.last_ble_sample_at,
    battery_pct = EXCLUDED.battery_pct,
    current_hr = EXCLUDED.current_hr,
    current_hrv_rmssd = EXCLUDED.current_hrv_rmssd,
    current_sdnn = COALESCE(EXCLUDED.current_sdnn, current_state.current_sdnn),
    current_dfa_alpha1 = COALESCE(EXCLUDED.current_dfa_alpha1, current_state.current_dfa_alpha1),
    current_respiratory_rate = COALESCE(EXCLUDED.current_respiratory_rate, current_state.current_respiratory_rate),
    current_cognitive_capacity = COALESCE(EXCLUDED.current_cognitive_capacity, current_state.current_cognitive_capacity),
    current_cognitive_label = COALESCE(EXCLUDED.current_cognitive_label, current_state.current_cognitive_label),
    current_readiness = COALESCE(EXCLUDED.current_readiness, current_state.current_readiness),
    current_illness_risk = COALESCE(EXCLUDED.current_illness_risk, current_state.current_illness_risk),
    current_sleep_stage = EXCLUDED.current_sleep_stage,
    current_hmm_state = COALESCE(EXCLUDED.current_hmm_state, current_state.current_hmm_state),
    current_hmm_state_id = COALESCE(EXCLUDED.current_hmm_state_id, current_state.current_hmm_state_id),
    baseline_hrv_avg = COALESCE(EXCLUDED.baseline_hrv_avg, current_state.baseline_hrv_avg),
    baseline_resting_hr = COALESCE(EXCLUDED.baseline_resting_hr, current_state.baseline_resting_hr),
    baseline_respiratory_rate = COALESCE(EXCLUDED.baseline_respiratory_rate, current_state.baseline_respiratory_rate),
    current_activity_state = EXCLUDED.current_activity_state;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  PERFORM public.log_trigger_failure(v_user, 'refresh_current_state_from_realtime',
                                     SQLSTATE, SQLERRM);
  RETURN NEW;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.recompute_health_metrics(p_user_id uuid, p_target_date date DEFAULT NULL::date)
 RETURNS health_metrics
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  target_date         date;
  win                 record;
  q                   record;
  s_score             numeric;
  r_score             numeric;
  consistency         numeric;
  result_row          health_metrics;
  has_open_alert      boolean;
  has_recent_backfill boolean;
  is_alcohol          boolean;
  st_clean            numeric;
  is_low_conf         boolean;
  ok                  boolean;
BEGIN
  target_date := COALESCE(p_target_date, (now() AT TIME ZONE 'Europe/Berlin')::date);

  SELECT detect_overnight_alcohol(p_user_id, target_date) INTO is_alcohol;
  st_clean := clean_skin_temp_day(p_user_id, target_date);

  SELECT * INTO win FROM detect_sleep_window(p_user_id, target_date);

  IF win.o_sleep_start IS NULL OR COALESCE(win.o_asleep_min, 0) < 60 THEN
    -- ===== NO-SCORE PATH (no usable sleep window) =====
    SELECT EXISTS (
      SELECT 1 FROM ble_freshness_alerts
      WHERE user_id = p_user_id AND state = 'open'
        AND detected_at >= NOW() - INTERVAL '3 hours'
    ) INTO has_open_alert;

    SELECT EXISTS (
      SELECT 1 FROM bridge_logs
      WHERE user_id = p_user_id
        AND created_at >= NOW() - INTERVAL '60 minutes'
        AND (
          (key = 'history_sync_gap_check'   AND value::text LIKE '%decision=download%')
          OR key = 'history_sync_request_sent'
          OR key = 'history_sync_complete'
          OR key = 'history_sync_batch_start'
        )
    ) INTO has_recent_backfill;

    IF has_open_alert OR has_recent_backfill THEN
      RAISE NOTICE 'recompute_health_metrics: sync in flight for %, deferring (alert=% backfill=%)',
        p_user_id, has_open_alert, has_recent_backfill;
      SELECT * INTO result_row FROM health_metrics
      WHERE user_id = p_user_id AND metric_date = target_date;
      IF result_row.metric_date IS NULL THEN RETURN NULL; END IF;
      RETURN result_row;
    END IF;

    INSERT INTO health_metrics (user_id, metric_date, source, alcohol_impact, skin_temp)
    VALUES (p_user_id, target_date, 'pg_recompute', CASE WHEN is_alcohol THEN 1.0 ELSE NULL END, st_clean)
    ON CONFLICT (user_id, metric_date) DO UPDATE SET
      alcohol_impact = CASE WHEN is_alcohol THEN 1.0 ELSE health_metrics.alcohol_impact END,
      skin_temp      = COALESCE(EXCLUDED.skin_temp, health_metrics.skin_temp);

    SELECT * INTO result_row FROM health_metrics
    WHERE user_id = p_user_id AND metric_date = target_date;
    RETURN result_row;
  END IF;

  -- ===== SCORED PATH =====
  is_low_conf := COALESCE(win.o_asleep_min, 0) < 240;

  -- v171/v172: was the night actually observed? A window the stager found is not the same
  -- thing as a night we watched. The gate clamps edge dropouts out first.
  SELECT * INTO q FROM sleep_window_quality(
    p_user_id, target_date, win.o_sleep_start, win.o_sleep_end, win.o_asleep_min);
  ok := COALESCE(q.o_complete, true);

  IF ok THEN
    -- v176: NULL here means genuine cold start (<5 prior nights of bedtime), and
    -- compute_sleep_score renormalises rather than substituting a fake 50.
    consistency := sleep_consistency_score(p_user_id, target_date);
    s_score := compute_sleep_score(
      win.o_total_min, win.o_asleep_min, win.o_deep_min, win.o_rem_min,
      win.o_efficiency_pct, consistency);
    r_score := compute_recovery_score(
      p_user_id, win.o_hrv_avg, win.o_resting_hr, s_score, target_date);
  ELSE
    s_score := NULL; r_score := NULL;
  END IF;

  INSERT INTO health_metrics (
    user_id, metric_date, source,
    sleep_start, sleep_end, sleep_hours,
    deep_sleep_min, rem_sleep_min, light_sleep_min, awake_min,
    sleep_efficiency_pct, sleep_score, recovery_score,
    hrv_avg, resting_hr,
    readiness_level, readiness_score, alcohol_impact, skin_temp,
    sleep_coverage_pct, sleep_max_gap_min, sleep_measured_min,
    sleep_complete, sleep_incomplete_reason, sleep_consistency_pct
  )
  VALUES (
    p_user_id, target_date, 'pg_recompute',
    COALESCE(q.o_start_used, win.o_sleep_start),
    COALESCE(q.o_end_used,   win.o_sleep_end),
    CASE WHEN ok THEN ROUND(win.o_asleep_min / 60.0, 1) END,
    win.o_deep_min, win.o_rem_min, win.o_light_min, win.o_awake_min,
    CASE WHEN ok THEN win.o_efficiency_pct END, s_score, r_score,
    CASE WHEN ok THEN win.o_hrv_avg END,
    CASE WHEN ok THEN win.o_resting_hr END,
    CASE WHEN NOT ok        THEN 'incomplete'
         WHEN is_low_conf   THEN 'low_confidence'
         WHEN r_score >= 67 THEN 'green'
         WHEN r_score >= 34 THEN 'yellow'
         ELSE 'red' END,
    r_score,
    CASE WHEN is_alcohol THEN 1.0 ELSE NULL END,
    st_clean,
    q.o_coverage_pct, q.o_max_gap_min, win.o_asleep_min,
    ok, q.o_reason,
    -- v183: the column existed and was NULL on every row for 90 days while this very
    -- function was already computing the value and throwing it away.
    CASE WHEN consistency IS NULL THEN NULL ELSE round(consistency) END
  )
  ON CONFLICT (user_id, metric_date) DO UPDATE SET
    source = 'pg_recompute',
    sleep_start = EXCLUDED.sleep_start,
    sleep_end = EXCLUDED.sleep_end,
    sleep_hours = EXCLUDED.sleep_hours,
    deep_sleep_min = EXCLUDED.deep_sleep_min,
    rem_sleep_min = EXCLUDED.rem_sleep_min,
    light_sleep_min = EXCLUDED.light_sleep_min,
    awake_min = EXCLUDED.awake_min,
    sleep_efficiency_pct = EXCLUDED.sleep_efficiency_pct,
    sleep_score = EXCLUDED.sleep_score,
    recovery_score = EXCLUDED.recovery_score,
    hrv_avg = EXCLUDED.hrv_avg,
    resting_hr = EXCLUDED.resting_hr,
    readiness_level = EXCLUDED.readiness_level,
    readiness_score = EXCLUDED.readiness_score,
    alcohol_impact = CASE WHEN is_low_conf
                          THEN CASE WHEN is_alcohol THEN 1.0 ELSE health_metrics.alcohol_impact END
                          ELSE EXCLUDED.alcohol_impact END,
    skin_temp = COALESCE(EXCLUDED.skin_temp, health_metrics.skin_temp),
    sleep_coverage_pct = EXCLUDED.sleep_coverage_pct,
    sleep_max_gap_min = EXCLUDED.sleep_max_gap_min,
    sleep_measured_min = EXCLUDED.sleep_measured_min,
    sleep_complete = EXCLUDED.sleep_complete,
    sleep_incomplete_reason = EXCLUDED.sleep_incomplete_reason,
    sleep_consistency_pct = COALESCE(EXCLUDED.sleep_consistency_pct, health_metrics.sleep_consistency_pct);

  SELECT * INTO result_row FROM health_metrics
  WHERE user_id = p_user_id AND metric_date = target_date;
  RETURN result_row;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════
-- sleep_consistency_pct has been NULL on every row for 90 days while
-- sleep_consistency_score() worked the whole time. Backfill 180 days so the app
-- and anything reading the column stop seeing a hole.
UPDATE health_metrics hm
   SET sleep_consistency_pct = round(sleep_consistency_score(hm.user_id, hm.metric_date))
 WHERE hm.user_id='372210e5-1dda-41b3-b759-5ff72293b8ff'
   AND hm.metric_date >= CURRENT_DATE - 180
   AND hm.sleep_hours IS NOT NULL
   AND hm.sleep_consistency_pct IS NULL;
