-- v196: personal baselines only learn from nights that were fully observed.
-- compute_recovery_score: the 30-night HRV/RHR baseline skips sleep_complete=false nights (10-08 had
--   stored a couch block as RHR). Replay: <=2 points on any night.
-- sleep_consistency_score: the 14-night bedtime spread skips incomplete and excluded nights.
--   August moved from 2-17 to 29-46, late September by -2..-5.
-- Rollback: supabase-migration-v196-rollback.sql

CREATE OR REPLACE FUNCTION public.compute_recovery_score(p_user_id uuid, p_hrv_avg numeric, p_resting_hr numeric, p_sleep_score numeric, p_date date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  n int;
  a_lh float8[]; a_lr float8[]; a_ss float8[];
  lh_med float8; lh_rsd float8; lr_med float8; lr_rsd float8; ss_med float8;
  hz float8; rz float8; ssd float8; z float8;
BEGIN
  IF p_hrv_avg IS NULL OR p_resting_hr IS NULL OR p_hrv_avg <= 0 OR p_resting_hr <= 0 THEN
    RETURN NULL;
  END IF;

  -- Baseline: his own fully observed nights strictly before p_date. WHOOP backfill, excluded and cut-off nights never count.
  SELECT count(*) INTO n
  FROM health_metrics
  WHERE user_id = p_user_id
    AND hrv_avg > 0 AND resting_hr > 0
    AND source IS DISTINCT FROM 'whoop_backfill' AND excluded IS NOT TRUE
    AND sleep_complete IS NOT FALSE
    AND metric_date >= p_date - 30 AND metric_date < p_date;

  -- Fewer than 7 nights in 30 days: fall back to the last 14 nights within 120 days.
  SELECT array_agg(ln(hrv_avg::float8)), array_agg(ln(resting_hr::float8)),
         array_agg(sleep_score::float8) FILTER (WHERE sleep_score IS NOT NULL)
    INTO a_lh, a_lr, a_ss
  FROM (
    SELECT hrv_avg, resting_hr, sleep_score
    FROM health_metrics
    WHERE user_id = p_user_id
      AND hrv_avg > 0 AND resting_hr > 0
      AND source IS DISTINCT FROM 'whoop_backfill' AND excluded IS NOT TRUE
      AND sleep_complete IS NOT FALSE
      AND metric_date >= p_date - CASE WHEN n >= 7 THEN 30 ELSE 120 END
      AND metric_date < p_date
    ORDER BY metric_date DESC
    LIMIT CASE WHEN n >= 7 THEN NULL ELSE 14 END
  ) b;

  IF COALESCE(array_length(a_lh, 1), 0) < 7 THEN
    RETURN NULL;
  END IF;

  -- Robust z: median and 1.4826*MAD, sd floored at 0.10 (log HRV) and 0.03 (log RHR), z clamped to +-3.
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v) INTO lh_med FROM unnest(a_lh) v;
  SELECT 1.4826 * percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(v - lh_med)) INTO lh_rsd FROM unnest(a_lh) v;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v) INTO lr_med FROM unnest(a_lr) v;
  SELECT 1.4826 * percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(v - lr_med)) INTO lr_rsd FROM unnest(a_lr) v;

  hz := GREATEST(-3, LEAST(3, (ln(p_hrv_avg::float8) - lh_med) / GREATEST(lh_rsd, 0.10)));
  rz := GREATEST(-3, LEAST(3, (ln(p_resting_hr::float8) - lr_med) / GREATEST(lr_rsd, 0.03)));

  IF p_sleep_score IS NOT NULL AND COALESCE(array_length(a_ss, 1), 0) >= 5 THEN
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v) INTO ss_med FROM unnest(a_ss) v;
    ssd := GREATEST(-4, LEAST(2, (p_sleep_score::float8 - ss_med) / 15));
    z := 0.707810948781312 + 0.5379232791569194 * hz - 0.24523685925817598 * rz + 0.4487981019303555 * ssd;
  ELSE
    z := 0.6172689205886958 + 0.48209512840223845 * hz - 0.37182913543345136 * rz;
  END IF;

  RETURN ROUND(LEAST(99, GREATEST(1, 100 / (1 + exp(-z))))::numeric);
END;
$function$;

CREATE OR REPLACE FUNCTION public.sleep_consistency_score(p_user_id uuid, p_target_date date, p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  WITH prior AS (
    SELECT EXTRACT(epoch FROM (
             (sleep_start AT TIME ZONE p_user_tz)
             - ((metric_date - 1)::timestamp + time '18:00')
           )) / 60.0 AS offset_min
    FROM health_metrics
    WHERE user_id = p_user_id
      AND metric_date BETWEEN p_target_date - 14 AND p_target_date - 1
      AND sleep_start IS NOT NULL
      AND sleep_complete IS NOT FALSE
      AND excluded IS NOT TRUE
  ),
  agg AS (SELECT count(*) AS n, stddev_samp(offset_min) AS sd FROM prior)
  SELECT CASE
           WHEN n < 5 OR sd IS NULL THEN NULL
           ELSE LEAST(100, GREATEST(0, 100 - GREATEST(0, sd - 20)))
         END
  FROM agg;
$function$;
