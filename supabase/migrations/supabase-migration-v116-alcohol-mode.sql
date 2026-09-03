-- migration v116_alcohol_mode.sql
-- Smart Alarm — Module 7: Alcohol Mode (the recovery override).
--
-- Source: this session's empirical split of his OWN 90d data (drunk vs sober median):
--   sleep   9.0h -> 5.0h   (the body truncates the night; -4h)
--   deep    125  -> 18min  (architecture collapses — almost no deep early)
--   rem     136  -> 45min  (REM suppressed by alcohol)
--   rhr     50   -> 61     (sleeping HR floor shifts UP ~+11 bpm)
--   recov   75   -> 59     (and 26-31 on the worst nights)
--
-- Physiology that drives the design: alcohol SEDATES but front-suppresses deep
-- sleep; the deep REBOUNDS in the back half of the night as BAC clears. The old
-- alarm force-waking at ~08:00 hit exactly that rebound window = it destroyed the
-- only recovery sleep he was going to get. He disabled the alarm because of this.
--
-- Alcohol mode therefore does three things the normal engine cannot:
--   1. Shifts the HR floor up (+offset) so deep-prob / readiness stop misreading
--      his elevated drunk sleeping HR as "awake" and waking him instantly.
--   2. NEVER forces an early wake without a hard calendar commitment. No commitment
--      => no alarm, only a humane midday backstop. Let the back-half rebound finish.
--   3. Targets a generous sleep OPPORTUNITY and a far more conservative wake gate.
--
-- detect_overnight_alcohol() (v106) already flags the morning-after; this adds a
-- manual pre-flag he can set in the evening before any overnight data exists.

-- ---------------------------------------------------------------------------
-- 1. Manual pre-flag (set in the evening; detection can't see the future)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.alcohol_flags (
  user_id         uuid    NOT NULL,
  flag_date       date    NOT NULL,                 -- the WAKE date (morning after)
  manual_drinking boolean NOT NULL DEFAULT true,
  note            text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, flag_date)
);
ALTER TABLE public.alcohol_flags ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS alcohol_flags_own ON public.alcohol_flags;
CREATE POLICY alcohol_flags_own ON public.alcohol_flags
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- Set / clear "I'm drinking tonight" for tomorrow's wake date.
CREATE OR REPLACE FUNCTION public.set_drinking_tonight(
  p_user_id uuid,
  p_drinking boolean DEFAULT true,
  p_for_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date + 1
)
RETURNS public.alcohol_flags
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE r public.alcohol_flags;
BEGIN
  INSERT INTO alcohol_flags(user_id, flag_date, manual_drinking)
  VALUES (p_user_id, p_for_date, p_drinking)
  ON CONFLICT (user_id, flag_date)
  DO UPDATE SET manual_drinking = EXCLUDED.manual_drinking, created_at = now()
  RETURNING * INTO r;
  RETURN r;
END;$f$;

-- True if this date is an alcohol-recovery morning (manual flag OR detection).
CREATE OR REPLACE FUNCTION public.is_alcohol_mode(
  p_user_id uuid,
  p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date
)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE m boolean; d boolean;
BEGIN
  SELECT manual_drinking INTO m FROM alcohol_flags
   WHERE user_id=p_user_id AND flag_date=p_date;
  IF COALESCE(m,false) THEN RETURN true; END IF;
  BEGIN
    d := detect_overnight_alcohol(p_user_id, p_date, 'Europe/Berlin');
  EXCEPTION WHEN OTHERS THEN d := false;
  END;
  RETURN COALESCE(d,false);
END;$f$;

-- ---------------------------------------------------------------------------
-- 2. Alcohol-shifted HR floor (his drunk sleeping HR sits ~+11 above sober)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.alcohol_hr_floor(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE base numeric; off numeric;
BEGIN
  SELECT median INTO base FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  base := COALESCE(base, 50);
  SELECT mu INTO off FROM personal_priors
   WHERE user_id=p_user_id AND param='alcohol_hr_offset';
  off := COALESCE(off, 10);
  RETURN round((base + off)::numeric, 1);
END;$f$;

-- Seed his real alcohol priors (offset +11, generous sleep target).
CREATE OR REPLACE FUNCTION public.seed_alcohol_priors(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
BEGIN
  INSERT INTO personal_priors(user_id, param, mu, tau2, n_obs, prior_mu, prior_tau2, updated_at)
  VALUES
    (p_user_id, 'alcohol_hr_offset',     11.0, 4.0, 0, 10.0, 9.0, now()),
    (p_user_id, 'alcohol_sleep_target_h', 9.0, 1.0, 0,  9.0, 1.0, now())
  ON CONFLICT (user_id, param) DO NOTHING;
END;$f$;

-- Re-learn the offset + drunk sleep stats from his own history (nightly cron / on demand).
CREATE OR REPLACE FUNCTION public.refresh_alcohol_priors(
  p_user_id uuid, p_lookback_days int DEFAULT 120
)
RETURNS TABLE(hr_offset numeric, drunk_sleep numeric, drunk_deep numeric, n_alcohol int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE drunk_rhr numeric; sober_rhr numeric; off numeric; dsleep numeric; ddeep numeric; ncnt int;
BEGIN
  WITH nights AS (
    SELECT d::date dt, detect_overnight_alcohol(p_user_id, d::date, 'Europe/Berlin') alc
    FROM generate_series(CURRENT_DATE - p_lookback_days, CURRENT_DATE - 1, '1 day') d
  )
  SELECT
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.resting_hr)     FILTER (WHERE n.alc),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.resting_hr)     FILTER (WHERE NOT n.alc),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.sleep_hours)    FILTER (WHERE n.alc),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hm.deep_sleep_min) FILTER (WHERE n.alc),
    count(*) FILTER (WHERE n.alc)
  INTO drunk_rhr, sober_rhr, dsleep, ddeep, ncnt
  FROM nights n
  JOIN health_metrics hm ON hm.user_id=p_user_id AND hm.metric_date=n.dt
  WHERE hm.sleep_hours > 0;

  IF ncnt >= 3 AND drunk_rhr IS NOT NULL AND sober_rhr IS NOT NULL THEN
    off := GREATEST(0, drunk_rhr - sober_rhr);
    PERFORM seed_alcohol_priors(p_user_id);                          -- ensure row exists
    PERFORM update_personal_prior(p_user_id, 'alcohol_hr_offset', off, 1.0);
  ELSE
    off := COALESCE((SELECT mu FROM personal_priors
                     WHERE user_id=p_user_id AND param='alcohol_hr_offset'), 10);
  END IF;

  hr_offset   := round(off::numeric, 1);
  drunk_sleep := round(dsleep::numeric, 1);
  drunk_deep  := round(ddeep::numeric);
  n_alcohol   := ncnt;
  RETURN NEXT;
END;$f$;

-- ---------------------------------------------------------------------------
-- 3. Alcohol-aware tonight plan (the core fix: no early forced wake)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.plan_tonight_alcohol(
  p_user_id uuid,
  p_wake_deadline timestamptz DEFAULT NULL,   -- a real commitment, or NULL for "free morning"
  p_prep_min int DEFAULT 45,
  p_travel_min int DEFAULT 0
)
RETURNS TABLE(
  alcohol_mode boolean, target_bedtime timestamptz, target_wake timestamptz,
  wake_window_start timestamptz, wake_window_end timestamptz,
  hard_backstop timestamptz, target_sleep_h numeric, hr_floor numeric, note text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE
  nstar numeric; floor_hr numeric; w_latest timestamptz; tw timestamptz;
  tz text := 'Europe/Berlin';
  tom date := (now() AT TIME ZONE 'Europe/Berlin')::date + 1;
  humane_min timestamptz; backstop timestamptz; parts text;
BEGIN
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

  alcohol_mode      := true;
  target_wake       := tw;
  wake_window_start := tw;
  wake_window_end   := backstop;
  hard_backstop     := backstop;
  target_sleep_h    := nstar;
  hr_floor          := floor_hr;
  target_bedtime    := tw - make_interval(secs => round(nstar*3600)::int);  -- informational
  note := parts;
  RETURN NEXT;
END;$f$;

-- ---------------------------------------------------------------------------
-- 4. Alcohol-aware wake poller (conservative; protects the rebound deep)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.should_wake_now_alcohol(
  p_user_id uuid, p_win_start timestamptz, p_win_end timestamptz, p_at timestamptz DEFAULT now()
)
RETURNS TABLE(wake boolean, wake_score int, deep_prob numeric, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE v_floor numeric; v_hr numeric; v_hrsd numeric; hr_low numeric; flat numeric; dp numeric;
BEGIN
  v_floor := alcohol_hr_floor(p_user_id);            -- shifted up ~+11 vs sober

  IF p_at >= p_win_end THEN
    wake := true;  wake_score := 100; deep_prob := NULL;
    reason := '⏰ backstop reached — waking gently now'; RETURN NEXT; RETURN;
  END IF;
  IF p_at < p_win_start THEN
    wake := false; wake_score := 0; deep_prob := NULL;
    reason := '😴 alcohol mode — no early alarm, still your window'; RETURN NEXT; RETURN;
  END IF;

  SELECT avg(heart_rate), stddev_samp(heart_rate) INTO v_hr, v_hrsd
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate>30
    AND recorded_at >= p_at - interval '5 minutes' AND recorded_at <= p_at;

  IF v_hr IS NULL THEN
    wake := false; wake_score := NULL; deep_prob := NULL;
    reason := 'no live data — holding (alcohol mode never force-wakes blind)';
    RETURN NEXT; RETURN;
  END IF;

  -- deep-prob against the ALCOHOL floor (drunk HR sits ~+11 higher); no noisy
  -- stage label — it's garbage on a fragmented drunk night.
  hr_low := LEAST(GREATEST((v_floor + 10 - v_hr)/10.0, 0), 1);
  flat   := LEAST(GREATEST((4 - COALESCE(v_hrsd,4))/4.0, 0), 1);
  dp := ROUND(LEAST(GREATEST(0.75*hr_low + 0.25*flat, 0), 1), 3);
  deep_prob := dp;
  wake_score := ROUND(100*(1-dp));

  -- MUCH more conservative than sober's 0.40 gate: only wake when clearly light.
  IF dp < 0.25 THEN
    wake := true;  reason := '🟢 clearly light + past your window — okay to wake';
  ELSE
    wake := false; reason := '🛑 still deep/heavy — hold, this is the recovery sleep your body missed earlier tonight';
  END IF;
  RETURN NEXT;
END;$f$;

-- ---------------------------------------------------------------------------
-- 5. One router the app calls: picks alcohol vs normal automatically
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.plan_tonight_auto(
  p_user_id uuid, p_prep_min int DEFAULT 45, p_travel_min int DEFAULT 0, p_winddown_min int DEFAULT 45
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE
  tom date := (now() AT TIME ZONE 'Europe/Berlin')::date + 1;
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
END;$f$;

COMMENT ON FUNCTION public.plan_tonight_auto IS
'v116 smart-alarm Module 7 router: if tomorrow is an alcohol-recovery morning (manual flag or detection), returns the alcohol plan (no early forced wake, shifted HR floor, conservative back-half-protecting wake); else the normal calendar backsolve. mode key tags which.';

COMMENT ON FUNCTION public.plan_tonight_alcohol IS
'v116 smart-alarm Module 7: alcohol-recovery night plan. With a hard commitment, sleeps to the last safe minute; with none, NO early alarm at all (humane 09:00 watch start, 12:00 backstop) to protect the back-half deep-sleep rebound that the old 08:00 force-wake destroyed.';
