-- migration v113_duration_flex.sql
-- Smart Alarm — Module 4: the sweet-spot flex.
--
-- Source: deep-research 2026-06-04 (kb 3599a20f), Domain 3. Targets his personal
-- optimal sleep (the v110 prior `optimal_sleep_hours`, empirically ~8h) and flexes
-- it nightly: +sleep when he's in debt / high strain / showing illness signs.
--
-- compute_sleep_debt: cumulative deficit vs target over last 7 days.
-- target_sleep_duration: tonight's target hours = base + debt + strain + illness.
-- refresh_optimal_sleep_prior: re-fit his peak from 90d history (bin-and-max on
--   recovery), nudging the Bayesian prior toward what his body actually shows.

CREATE OR REPLACE FUNCTION public.compute_sleep_debt(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE base numeric; debt numeric;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);
  SELECT COALESCE(sum(GREATEST(0, base - sleep_hours)), 0) INTO debt
  FROM health_metrics
  WHERE user_id=p_user_id AND sleep_hours > 0
    AND metric_date >= CURRENT_DATE - 7 AND metric_date < CURRENT_DATE;
  RETURN ROUND(debt, 2);
END;$f$;

CREATE OR REPLACE FUNCTION public.target_sleep_duration(
  p_user_id uuid, p_for_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date + 1
)
RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_illness numeric, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE base numeric; debt numeric; ystrain numeric; strainbase numeric;
        yrhr numeric; rhrmed numeric; dd numeric; ds numeric; di numeric; parts text;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  debt := compute_sleep_debt(p_user_id);
  dd := LEAST(1.0, 0.25 * debt);   -- ~4h cumulative deficit -> +1h, capped

  SELECT strain_score INTO ystrain FROM health_metrics
   WHERE user_id=p_user_id AND metric_date = CURRENT_DATE - 1;
  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  ds := CASE WHEN ystrain IS NOT NULL AND strainbase IS NOT NULL AND ystrain > strainbase*1.15
             THEN 0.3 ELSE 0 END;

  SELECT resting_hr INTO yrhr FROM health_metrics
   WHERE user_id=p_user_id AND metric_date = CURRENT_DATE - 1;
  SELECT median INTO rhrmed FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  di := CASE WHEN yrhr IS NOT NULL AND rhrmed IS NOT NULL AND yrhr > rhrmed + 3
             THEN 0.5 ELSE 0 END;

  target_h := ROUND(LEAST(GREATEST(base + dd + ds + di, base - 0.5), base + 2), 2);
  base_h := base; d_debt := ROUND(dd,2); d_strain := ds; d_illness := di;

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || round(dd,1) || ' debt'; END IF;
  IF ds > 0 THEN parts := parts || ' +0.3 high strain'; END IF;
  IF di > 0 THEN parts := parts || ' +0.5 illness signs'; END IF;
  note := parts || ' = aim for ' || target_h || 'h';
  RETURN NEXT;
END;$f$;

CREATE OR REPLACE FUNCTION public.refresh_optimal_sleep_prior(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE best_h numeric;
BEGIN
  SELECT hrs INTO best_h FROM (
    SELECT round(sleep_hours) AS hrs, count(*) AS c,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY recovery_score) AS mr
    FROM health_metrics
    WHERE user_id=p_user_id AND sleep_hours > 0 AND recovery_score > 0
      AND metric_date >= CURRENT_DATE - 120
    GROUP BY round(sleep_hours)
    HAVING count(*) >= 3
    ORDER BY mr DESC
    LIMIT 1
  ) z;
  IF best_h IS NOT NULL THEN
    PERFORM update_personal_prior(p_user_id, 'optimal_sleep_hours', best_h, 0.6);
  END IF;
  RETURN best_h;
END;$f$;

COMMENT ON FUNCTION public.target_sleep_duration IS
'v113 smart-alarm Module 4: tonight target sleep = personal optimum (prior) + debt + strain + illness flex, clamped [base-0.5, base+2]. Drives "sleep in when wrecked, wake earlier when recovered".';
