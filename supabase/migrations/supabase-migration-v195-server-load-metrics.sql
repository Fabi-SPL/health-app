-- v195: Moves every LOAD column server-side (Hard Constraint 7: thin client).
-- Today these columns have NO server writer: the iOS app computes them on-device
-- (RecoveryEngine.updateStrain / updateTrainingLoad) and PATCHes them via SupabaseClient.upsertDailyMetrics.
-- edwards_trimp is computed in the app but never sent, so it has never been written (0 rows ever).
--
-- Definitions (all from realtime_health, Berlin calendar day, one value per MINUTE that has data):
--   HRmax          = 208 - 0.7*age (Tanaka 2001; age from user_body_profile), fallback 190
--   edwards_trimp  = sum of minutes x zone weight, zones 50-60/60-70/70-80/80-90/90-100 %HRmax -> 1..5 (Edwards 1993)
--   strain_score   = 21 * (1 - exp(-edwards_trimp / 200))  (asymptotic 0-21; tau=200 is UNCALIBRATED)
--   strain_physical= same mapping over minutes >= 60 %HRmax only
--   strain_autonomic / strain_stress = remainder (strain - physical) split by median DFA-a1 of the
--                    active minutes, same split rule the app used (heuristic, unvalidated)
--   training load  = edwards_trimp of minutes >= 60 %HRmax; a day counts only with >= 720 min of data
--   training_monotony = mean / sample SD of the last 7 days' load, needs >= 6 valid days (Foster 1998)
--   training_strain   = 7-day load (mean*7) x monotony (Foster 1998)
--   acwr              = mean load last 7 d / mean load last 28 d (coupled rolling), needs >= 5/7 and >= 20/28
-- Insufficient data writes NULL, so a strap hole reads as "no data", never as a rest day or a default 1.0.

CREATE OR REPLACE FUNCTION public.compute_load_metrics(p_user_id uuid, p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Berlin'::text))::date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_hrmax numeric;
  v_today date := (now() AT TIME ZONE 'Europe/Berlin')::date;
BEGIN
  SELECT 208 - 0.7 * age INTO v_hrmax FROM user_body_profile WHERE user_id = p_user_id;
  v_hrmax := COALESCE(v_hrmax, 190);

  WITH mins AS (
    SELECT (date_trunc('minute', recorded_at) AT TIME ZONE 'Europe/Berlin')::date AS d,
           date_trunc('minute', recorded_at) AS mi, avg(heart_rate) AS hr, avg(dfa_alpha1) AS dfa
    FROM realtime_health
    WHERE user_id = p_user_id AND heart_rate BETWEEN 30 AND 230
      AND recorded_at >= ((p_date - 27)::timestamp AT TIME ZONE 'Europe/Berlin')
      AND recorded_at <  ((p_date + 1)::timestamp AT TIME ZONE 'Europe/Berlin')
    GROUP BY 1, 2
  ), z AS (
    SELECT d, dfa,
           CASE WHEN hr >= 0.9 * v_hrmax THEN 5 WHEN hr >= 0.8 * v_hrmax THEN 4 WHEN hr >= 0.7 * v_hrmax THEN 3
                WHEN hr >= 0.6 * v_hrmax THEN 2 WHEN hr >= 0.5 * v_hrmax THEN 1 ELSE 0 END AS w
    FROM mins
  ), day AS (
    SELECT d, count(*) AS cov_min, sum(w) AS trimp,
           COALESCE(sum(w) FILTER (WHERE w >= 2), 0) AS trimp_hi,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY dfa) FILTER (WHERE dfa > 0 AND w >= 1))::numeric AS dfa_med
    FROM z GROUP BY d
  ), cal AS (
    SELECT g::date AS d FROM generate_series(p_date - 27, p_date, interval '1 day') g
  ), s AS (
    SELECT c.d, COALESCE(dy.cov_min, 0) AS cov_min, dy.trimp, dy.trimp_hi, dy.dfa_med,
           CASE WHEN c.d = v_today
                THEN COALESCE(dy.cov_min, 0) >= 0.5 * EXTRACT(epoch FROM (now() - (c.d::timestamp AT TIME ZONE 'Europe/Berlin'))) / 60
                ELSE COALESCE(dy.cov_min, 0) >= 720 END AS strain_ok,
           CASE WHEN COALESCE(dy.cov_min, 0) >= 720 THEN dy.trimp_hi END AS load
    FROM cal c LEFT JOIN day dy USING (d)
  ), w AS (
    SELECT s.*,
           count(load) OVER w7 AS n7, avg(load) OVER w7 AS m7, stddev_samp(load) OVER w7 AS sd7,
           count(load) OVER w28 AS n28, avg(load) OVER w28 AS m28
    FROM s
    WINDOW w7 AS (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW),
           w28 AS (ORDER BY d ROWS BETWEEN 27 PRECEDING AND CURRENT ROW)
  ), r AS (
    SELECT d, trimp, strain_ok, dfa_med,
           CASE WHEN strain_ok THEN 21 * (1 - exp(-trimp / 200.0)) END AS ss,
           CASE WHEN strain_ok THEN 21 * (1 - exp(-trimp_hi / 200.0)) END AS sp,
           GREATEST(0, LEAST(0.5, (1.5 - COALESCE(dfa_med, 1.2)) / 1.5)) AS dfa_frac,
           CASE WHEN n7 >= 6 AND sd7 > 0 THEN (m7 / sd7)::numeric END AS tm,
           CASE WHEN n7 >= 6 AND sd7 > 0 THEN (m7 * 7 * (m7 / sd7))::numeric END AS ts,
           CASE WHEN n7 >= 5 AND n28 >= 20 AND m28 > 0 THEN (m7 / m28)::numeric END AS acwr
    FROM w WHERE d = p_date
  )
  UPDATE health_metrics hm SET
    edwards_trimp     = CASE WHEN r.strain_ok THEN r.trimp END,
    strain_score      = round(r.ss, 1),
    strain_physical   = round(r.sp, 1),
    strain_autonomic  = CASE WHEN r.strain_ok THEN round(GREATEST(0, r.ss - r.sp) * r.dfa_frac, 1) END,
    strain_stress     = CASE WHEN r.strain_ok THEN round(GREATEST(0, r.ss - r.sp) * (1 - r.dfa_frac), 1) END,
    training_monotony = round(r.tm, 2),
    training_strain   = round(r.ts),
    acwr              = round(r.acwr, 2)
  FROM r
  WHERE hm.user_id = p_user_id AND hm.metric_date = p_date;
END;$function$;

-- Stop the app's PATCH from overwriting the server values (no app build needed). PostgREST sets the JWT
-- role; pg_cron / service-role writes pass through untouched.
CREATE OR REPLACE FUNCTION public.guard_server_load_columns()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'role', '') IN ('authenticated', 'anon') THEN
    NEW.strain_score      := OLD.strain_score;
    NEW.strain_physical   := OLD.strain_physical;
    NEW.strain_stress     := OLD.strain_stress;
    NEW.strain_autonomic  := OLD.strain_autonomic;
    NEW.edwards_trimp     := OLD.edwards_trimp;
    NEW.training_monotony := OLD.training_monotony;
    NEW.training_strain   := OLD.training_strain;
    NEW.acwr              := OLD.acwr;
  END IF;
  RETURN NEW;
END;$function$;

DROP TRIGGER IF EXISTS trg_guard_server_load_columns ON public.health_metrics;
CREATE TRIGGER trg_guard_server_load_columns BEFORE UPDATE ON public.health_metrics
  FOR EACH ROW EXECUTE FUNCTION public.guard_server_load_columns();

-- Every 15 min for today, and once after the 05:00 UTC recompute for yesterday.
SELECT cron.schedule('load_metrics_15min', '*/15 * * * *',
  $$SELECT public.compute_load_metrics('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)$$);
SELECT cron.schedule('load_metrics_finalize', '10 5 * * *',
  $$SELECT public.compute_load_metrics('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, (now() AT TIME ZONE 'Europe/Berlin')::date - 1)$$);
