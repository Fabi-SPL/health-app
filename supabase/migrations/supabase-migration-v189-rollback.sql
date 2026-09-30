-- v189 rollback: restores the detect_live_sleep_onset definition live before 2026-09-30
CREATE OR REPLACE FUNCTION public.detect_live_sleep_onset(p_user_id uuid, p_since timestamp with time zone, p_now timestamp with time zone DEFAULT now(), p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  rhr numeric; night_p05 int; adj int; thresh numeric; onset timestamptz;
BEGIN
  -- Resting-HR anchor: current_state (p05 baseline, ~49) -> 30d baseline median -> 50.
  rhr := COALESCE(
    (SELECT baseline_resting_hr FROM current_state WHERE user_id=p_user_id),
    (SELECT median FROM personal_baselines WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30),
    50);

  -- Adaptive onset threshold: mirror detect_sleep_window's sober geometry so a hot/stressed
  -- night with an elevated floor is still captured. Onset = HR settling into his sleeping band.
  SELECT round(percentile_cont(0.05) WITHIN GROUP (ORDER BY heart_rate))::int
    INTO night_p05
  FROM realtime_health
  WHERE user_id=p_user_id AND recorded_at >= p_since AND recorded_at < p_now
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  IF night_p05 IS NULL THEN RETURN NULL; END IF;   -- FAIL SAFE: no data
  adj := 12 + GREATEST(0, night_p05 - 54);
  thresh := GREATEST(rhr + 11, LEAST(80, night_p05 + adj));

  WITH mb AS (
    SELECT date_trunc('minute', recorded_at) AS m_ts,
           avg(heart_rate)::numeric AS hr_avg,
           avg(COALESCE(accel_mag_mg, 0))::numeric AS accel_avg,
           avg(hrv_rmssd) FILTER (WHERE hrv_rmssd>0)::numeric AS hrv_avg
    FROM realtime_health
    WHERE user_id=p_user_id AND recorded_at >= p_since AND recorded_at < p_now
      AND heart_rate IS NOT NULL AND heart_rate > 30
    GROUP BY 1
  ),
  smoothed AS (
    SELECT m_ts, hr_avg, accel_avg, hrv_avg,
           avg(hr_avg) OVER (ORDER BY m_ts ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS hr_smooth
    FROM mb
  ),
  flagged AS (
    -- low HR (sleeping band) AND low motion if motion is actually recorded (else pass).
    SELECT m_ts,
           CASE WHEN hr_smooth < thresh
                 AND (accel_avg IS NULL OR accel_avg < 40) THEN 1 ELSE 0 END AS is_low
    FROM smoothed
  ),
  sustained AS (
    SELECT m_ts, is_low,
      SUM(is_low) OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 4 FOLLOWING) AS fwd5,
      COUNT(*)    OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 4 FOLLOWING) AS n5
    FROM flagged
  )
  SELECT MIN(m_ts) INTO onset
  FROM sustained
  WHERE fwd5 = 5 AND n5 = 5;   -- >=5 consecutive sub-threshold minutes

  RETURN onset;
END;$function$

;
