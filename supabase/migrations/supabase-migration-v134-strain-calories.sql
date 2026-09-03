-- v134: Daily Strain (0-100) + calorie estimates from continuous HR load.
-- Strain = accumulated cardiovascular load = sum(HR - resting) over the day, in bpm-hours,
-- mapped to 0-100. Captures all-day NEAT (cooking/cleaning/pacing), not just workouts.
-- This is the SAME HR signal that drains the live Body Battery (v129 integral) — strain is
-- "how much you spent", battery is "how much is left". Two views of one thing.
--
-- Calories: pure HR->VO2 over the whole day overestimates wildly for Fabi (caffeine + high
-- resting HR inflate HR without real O2 cost). So active kcal is derived from the LOAD
-- (calibrated), and BMR from the body profile (Mifflin-St Jeor). Honest, sane numbers.

-- bpm-hours of load over a window (sum of HR above personal resting floor)
CREATE OR REPLACE FUNCTION public.body_load_bpmh(p_user_id uuid, p_from timestamptz, p_to timestamptz)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
  SELECT COALESCE(sum(GREATEST(0, heart_rate
           - COALESCE((SELECT median FROM personal_baselines
                       WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3), 50)
         )) * 10/3600.0, 0)
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate>30 AND recorded_at>=p_from AND recorded_at<=p_to;
$$;

-- daily strain 0-100 (today = up to now, accumulating; past = full day)
CREATE OR REPLACE FUNCTION public.body_daily_strain(p_user_id uuid,
  p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
  SELECT LEAST(100, round(body_load_bpmh(
    p_user_id,
    ((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin',
    LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  ) / 7.0));
$$;

-- accumulating strain curve through the day (for an in-app chart)
CREATE OR REPLACE FUNCTION public.body_strain_series(p_user_id uuid,
  p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date)
RETURNS TABLE(at timestamptz, value numeric) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
  WITH ticks AS (
    SELECT generate_series(
      ((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin',
      LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin'),
      interval '15 min') AS t
  )
  SELECT t, LEAST(100, round(body_load_bpmh(
    p_user_id, ((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin', t) / 7.0))
  FROM ticks ORDER BY t;
$$;

-- BMR + active + total daily energy (kcal). Active is load-derived (not the HR-VO2 blowup).
CREATE OR REPLACE FUNCTION public.body_daily_calories(p_user_id uuid,
  p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date)
RETURNS TABLE(bmr integer, active_kcal integer, tdee integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
  WITH p AS (SELECT weight_kg w, height_cm h, age a FROM user_body_profile WHERE user_id=p_user_id),
  l AS (SELECT body_load_bpmh(
          p_user_id,
          ((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin',
          LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin')) lb)
  SELECT round(10*p.w + 6.25*p.h - 5*p.a + 5)::int AS bmr,         -- Mifflin-St Jeor (male)
         round((SELECT lb FROM l) * 1.5)::int AS active_kcal,       -- load -> active kcal (calibrated)
         round(10*p.w + 6.25*p.h - 5*p.a + 5 + (SELECT lb FROM l) * 1.5)::int AS tdee
  FROM p;
$$;
