-- v173 — Measure intake without logging a single meal.
--
-- He hates food logging and stopped doing it. Fair. The instrument was never
-- the point — the number was. Energy balance runs backwards just as well:
--
--   intake = TDEE + (weight change in kcal)
--
-- The strap already measures burn every day (body_daily_calories reads HR
-- load, so a bike ride counts itself — nothing to log there either). So the
-- only input left is a number on a scale, once a morning.
--
-- Two things this gets right that a naive first-vs-last diff does not:
--
--   1. Linear regression over the whole window, not endpoint minus endpoint.
--      One salty dinner or one dehydrated morning moves a two-point diff by
--      600 kcal/day. A slope through 10 points barely notices it.
--
--   2. Dead biometric days are excluded from the TDEE average, same lesson
--      as v163 — a day the strap was off is not a day he lay still.
--
-- 7700 kcal/kg is fat-tissue energy density. Early loss carries water and
-- glycogen with it, which is exactly why this needs 10+ days before it says
-- anything. Under that it reports its own uncertainty instead of a number.

-- One weight per day. Stepping on the scale twice should correct, not append.
CREATE UNIQUE INDEX IF NOT EXISTS body_composition_log_user_date_uniq
  ON public.body_composition_log (user_id, measured_at);

-- OUT params are named around the table's own columns on purpose — `measured_at`
-- and `weight_kg` as OUT names make every reference inside the INSERT ambiguous.
DROP FUNCTION IF EXISTS public.log_weight(numeric, date, uuid);
CREATE OR REPLACE FUNCTION public.log_weight(
  p_kg numeric,
  p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Berlin'::text))::date,
  p_user_id uuid DEFAULT NULL
)
RETURNS TABLE (logged_on date, kg numeric, delta_kg numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_user uuid := coalesce(p_user_id, auth.uid());
  v_prev numeric;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'no user';
  END IF;
  IF p_kg IS NULL OR p_kg < 30 OR p_kg > 250 THEN
    RAISE EXCEPTION 'weight % kg is outside a plausible range', p_kg;
  END IF;

  SELECT b.weight_kg INTO v_prev
    FROM body_composition_log b
   WHERE b.user_id = v_user AND b.measured_at < p_date AND b.weight_kg IS NOT NULL
   ORDER BY b.measured_at DESC LIMIT 1;

  INSERT INTO body_composition_log (user_id, measured_at, weight_kg, method)
  VALUES (v_user, p_date, p_kg, 'scale')
  ON CONFLICT (user_id, measured_at)
  DO UPDATE SET weight_kg = EXCLUDED.weight_kg,
                method    = coalesce(body_composition_log.method, 'scale');

  -- Keep the profile in step, otherwise BMR keeps using a stale bodyweight.
  UPDATE user_body_profile SET weight_kg = p_kg WHERE user_id = v_user;

  RETURN QUERY SELECT p_date, p_kg, round(p_kg - v_prev, 2);
END $function$;

GRANT EXECUTE ON FUNCTION public.log_weight(numeric, date, uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.intake_backsolve(
  p_user_id uuid DEFAULT NULL,
  p_days int DEFAULT 14
)
RETURNS TABLE (
  n_weighins int, span_days int,
  first_kg numeric, last_kg numeric,
  trend_kg_per_week numeric,
  avg_tdee int, est_intake int, est_balance int,
  confidence text, headline text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_user  uuid := coalesce(p_user_id, auth.uid());
  v_today date := (now() AT TIME ZONE 'Europe/Berlin')::date;
  w record; v_slope numeric; v_tdee int;
BEGIN
  SELECT count(*)::int                                              AS n,
         min(measured_at)                                           AS d0,
         max(measured_at)                                           AS d1,
         regr_slope(weight_kg, (measured_at - v_today))             AS slope,
         (array_agg(weight_kg ORDER BY measured_at))[1]             AS w0,
         (array_agg(weight_kg ORDER BY measured_at DESC))[1]        AS w1
    INTO w
    FROM body_composition_log
   WHERE user_id = v_user
     AND weight_kg IS NOT NULL
     AND measured_at > v_today - p_days;

  n_weighins := coalesce(w.n, 0);
  span_days  := CASE WHEN w.n > 0 THEN (w.d1 - w.d0) ELSE 0 END;
  first_kg   := w.w0;
  last_kg    := w.w1;

  -- Average burn over the window, ignoring days the strap recorded nothing.
  SELECT round(avg(x.bmr + x.active_kcal) FILTER (WHERE x.active_kcal > 0))::int
    INTO v_tdee
    FROM generate_series(v_today - p_days, v_today - 1, '1 day') d
    CROSS JOIN LATERAL body_daily_calories(v_user, d::date) x;
  avg_tdee := v_tdee;

  v_slope := w.slope;                       -- kg per day, negative = losing
  trend_kg_per_week := round(v_slope * 7, 2);

  confidence := CASE
    WHEN n_weighins < 3 OR v_slope IS NULL THEN 'none'
    WHEN span_days  < 10                   THEN 'low'
    WHEN n_weighins < 8                    THEN 'ok'
    ELSE                                        'good'
  END;

  IF confidence = 'none' OR v_tdee IS NULL THEN
    est_intake := NULL; est_balance := NULL;
  ELSE
    est_balance := round(v_slope * 7700)::int;      -- kcal/day above or below burn
    est_intake  := v_tdee + est_balance;
  END IF;

  headline := CASE
    WHEN n_weighins = 0 THEN 'No weigh-ins yet — step on the scale to start'
    WHEN confidence = 'none' THEN
      'Need ' || (3 - n_weighins) || ' more weigh-ins'
    WHEN confidence = 'low' THEN
      'Reading forming — ' || (10 - span_days) || ' more days for a real number'
    WHEN est_balance BETWEEN -120 AND 120 THEN
      'Holding steady — eating about what you burn (~' || est_intake || ')'
    WHEN est_balance < 0 THEN
      'Losing ' || abs(trend_kg_per_week) || ' kg/wk — eating ~' || est_intake
      || ', about ' || abs(est_balance) || ' under'
    ELSE
      'Gaining ' || trend_kg_per_week || ' kg/wk — eating ~' || est_intake
      || ', about ' || est_balance || ' over'
  END;

  RETURN NEXT;
END $function$;

GRANT EXECUTE ON FUNCTION public.intake_backsolve(uuid, int) TO authenticated;
