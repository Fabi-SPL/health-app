-- v205: a flat strap overnight no longer blanks the day's strain.
-- compute_load_metrics showed today's strain only once half the minutes since midnight had data. After the
-- strap ran flat at 20:30 on 2026-10-09 and came back at 09:24, that bar would not be met until ~17:30, so
-- the Today and Strain screens said "No data" all day. Night minutes (22-08) inside a strap_battery_empty
-- outage now leave the denominator. Daytime dead minutes still count, so a workout missed by a dead strap
-- cannot pass as a low-strain day. Training load (ACWR, monotony) keeps its strict 720-minute rule.
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
  ), dead AS (
    -- v205: night minutes (22-08) with the strap switched off for lack of battery. Nothing can be recorded
    -- then and asleep they add no strain, so they no longer count against coverage. On 2026-10-10 the strap
    -- was flat until 09:24 and today's strain stayed blank until about 17:30.
    SELECT (m AT TIME ZONE 'Europe/Berlin')::date AS d, count(*) AS dead_min
    FROM strap_outages o,
         generate_series(date_trunc('minute', o.started_at), COALESCE(o.ended_at, now()) - interval '1 minute', interval '1 minute') m
    WHERE o.user_id = p_user_id AND o.cause = 'strap_battery_empty'
      AND o.started_at < ((p_date + 1)::timestamp AT TIME ZONE 'Europe/Berlin')
      AND COALESCE(o.ended_at, now()) > ((p_date - 27)::timestamp AT TIME ZONE 'Europe/Berlin')
      AND (extract(hour FROM m AT TIME ZONE 'Europe/Berlin') >= 22 OR extract(hour FROM m AT TIME ZONE 'Europe/Berlin') < 8)
    GROUP BY 1
  ), s AS (
    SELECT c.d, COALESCE(dy.cov_min, 0) AS cov_min, dy.trimp, dy.trimp_hi, dy.dfa_med,
           CASE WHEN c.d = v_today
                THEN COALESCE(dy.cov_min, 0) >= 0.5 * GREATEST(0, EXTRACT(epoch FROM (now() - (c.d::timestamp AT TIME ZONE 'Europe/Berlin'))) / 60
                                                             - COALESCE(dd.dead_min, 0))
                ELSE COALESCE(dy.cov_min, 0) >= 0.5 * (1440 - COALESCE(dd.dead_min, 0)) END AS strain_ok,
           CASE WHEN COALESCE(dy.cov_min, 0) >= 720 THEN dy.trimp_hi END AS load
    FROM cal c LEFT JOIN day dy USING (d) LEFT JOIN dead dd USING (d)
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
