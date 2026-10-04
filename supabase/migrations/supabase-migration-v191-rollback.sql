-- v191 rollback: restores the compute_recovery_score definition live before 2026-10-04 (v153 percentile blend)
CREATE OR REPLACE FUNCTION public.compute_recovery_score(p_user_id uuid, p_hrv_avg numeric, p_resting_hr numeric, p_sleep_score numeric, p_date date DEFAULT CURRENT_DATE)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  history_days int;
  hrv_pct numeric;
  rhr_pct_inv numeric;
  s_score numeric;
  baseline_hrv numeric;
  hrv_sd       numeric;
  median_rhr   numeric;
  rhr_sd       numeric;
  v_hrv_med numeric; v_hrv_mad numeric; v_rhr_med numeric; v_rhr_mad numeric;
  hrv_z numeric;
  rhr_z numeric;
  hrv_component numeric;
  rhr_component numeric;
  sleep_component numeric;
  total_weight numeric := 0;
  weighted_sum numeric := 0;
  raw numeric;
  recovery_anchor numeric := 66;
  stretch_k numeric := 1.15;
  score_floor numeric := 5;
BEGIN
  -- #27: cold-start centers on the user's OWN baselines, not stale population constants.
  SELECT median, mad INTO v_hrv_med, v_hrv_mad FROM personal_baselines
    WHERE user_id=p_user_id AND metric='hrv_avg' AND window_days=30;
  SELECT median, mad INTO v_rhr_med, v_rhr_mad FROM personal_baselines
    WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  baseline_hrv := COALESCE(v_hrv_med, 64.4);   -- population fallback only for a zero-baseline user
  median_rhr   := COALESCE(v_rhr_med, 58);
  hrv_sd := GREATEST(COALESCE(v_hrv_mad,0)*1.4826, 8);
  rhr_sd := GREATEST(COALESCE(v_rhr_mad,0)*1.4826, 4);

  -- #24: window strictly BEFORE the target day (no self-inclusion), anchored on p_date.
  SELECT COUNT(*) INTO history_days
  FROM health_metrics
  WHERE user_id = p_user_id
    AND hrv_avg IS NOT NULL AND hrv_avg > 0
    AND metric_date >= p_date - 30
    AND metric_date < p_date;

  -- Cold-start path: <7 days of usable history
  IF history_days < 7 THEN
    IF p_hrv_avg IS NOT NULL AND p_hrv_avg > 0 THEN
      hrv_z := (p_hrv_avg - baseline_hrv) / hrv_sd;
      hrv_component := sigmoid(hrv_z) * 100;
    ELSE
      hrv_component := 50;
    END IF;

    IF p_resting_hr IS NOT NULL AND p_resting_hr > 0 THEN
      rhr_z := (median_rhr - p_resting_hr) / rhr_sd;
      rhr_component := sigmoid(rhr_z) * 100;
    ELSE
      rhr_component := 50;
    END IF;

    sleep_component := COALESCE(p_sleep_score, 50);

    RETURN ROUND(LEAST(100, GREATEST(score_floor,
      hrv_component * 0.50 + rhr_component * 0.20 + sleep_component * 0.30
    )));
  END IF;

  -- Personal-percentile path (>=7 days history)
  IF p_hrv_avg IS NOT NULL AND p_hrv_avg > 0 THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE hrv_avg < p_hrv_avg)::numeric +
      0.5 * COUNT(*) FILTER (WHERE hrv_avg = p_hrv_avg)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE hrv_avg > 0), 0)
    INTO hrv_pct
    FROM health_metrics
    WHERE user_id = p_user_id
      AND hrv_avg IS NOT NULL AND hrv_avg > 0
      AND metric_date >= p_date - 30
      AND metric_date < p_date;
  ELSE
    hrv_pct := NULL;
  END IF;

  IF p_resting_hr IS NOT NULL AND p_resting_hr > 0 THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE resting_hr > p_resting_hr)::numeric +
      0.5 * COUNT(*) FILTER (WHERE resting_hr = p_resting_hr)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE resting_hr > 0), 0)
    INTO rhr_pct_inv
    FROM health_metrics
    WHERE user_id = p_user_id
      AND resting_hr IS NOT NULL AND resting_hr > 0
      AND metric_date >= p_date - 30
      AND metric_date < p_date;
  ELSE
    rhr_pct_inv := NULL;
  END IF;

  -- #29: convert the absolute sleep_score to a self-percentile so all three inputs share the
  -- 0-100 percentile scale centered ~50 (a normal HRV/RHR/sleep night now anchors at 66, not ~72).
  IF p_sleep_score IS NOT NULL THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE sleep_score < p_sleep_score)::numeric +
      0.5 * COUNT(*) FILTER (WHERE sleep_score = p_sleep_score)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE sleep_score IS NOT NULL), 0)
    INTO s_score
    FROM health_metrics
    WHERE user_id = p_user_id
      AND sleep_score IS NOT NULL
      AND metric_date >= p_date - 30
      AND metric_date < p_date;
    s_score := COALESCE(s_score, p_sleep_score);   -- fallback to absolute if no sleep history yet
  ELSE
    s_score := 50;
  END IF;

  IF hrv_pct IS NOT NULL THEN
    weighted_sum := weighted_sum + hrv_pct * 0.55;
    total_weight := total_weight + 0.55;
  END IF;
  IF rhr_pct_inv IS NOT NULL THEN
    weighted_sum := weighted_sum + rhr_pct_inv * 0.30;
    total_weight := total_weight + 0.30;
  END IF;
  weighted_sum := weighted_sum + s_score * 0.15;
  total_weight := total_weight + 0.15;

  IF total_weight = 0 THEN
    RETURN 50;
  END IF;

  raw := weighted_sum / total_weight;

  RETURN ROUND(LEAST(100, GREATEST(score_floor, recovery_anchor + (raw - 50) * stretch_k)));
END;
$function$;
