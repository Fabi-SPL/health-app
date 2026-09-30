-- v189: sleep onset was detected minutes after the 20:00 auto-arm (resting evening HR sat under an
-- uncapped threshold), so earliest/target wake were anchored hours early: 09-22 fired 04:46 after 3.5h real sleep.
-- Threshold capped at resting HR + 15, 10 contiguous low minutes, and the next hour must be >= 80% low.
-- Backtest over 21 armed nights 08-26..09-28: never more than 1 min before real sleep start, median 10 min after, max 59.
-- Rollback: supabase-migration-v189-rollback.sql (the live definition this replaces).

CREATE OR REPLACE FUNCTION public.detect_live_sleep_onset(p_user_id uuid, p_since timestamp with time zone, p_now timestamp with time zone DEFAULT now(), p_user_tz text DEFAULT 'Europe/Berlin'::text)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  rhr numeric; night_p05 int; adj int; thresh numeric; onset timestamptz;
BEGIN
  rhr := COALESCE(
    (SELECT baseline_resting_hr FROM current_state WHERE user_id=p_user_id),
    (SELECT median FROM personal_baselines WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30),
    50);

  SELECT round(percentile_cont(0.05) WITHIN GROUP (ORDER BY heart_rate))::int
    INTO night_p05
  FROM realtime_health
  WHERE user_id=p_user_id AND recorded_at >= p_since AND recorded_at < p_now
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  IF night_p05 IS NULL THEN RETURN NULL; END IF;
  adj := 12 + GREATEST(0, night_p05 - 54);
  thresh := LEAST(rhr + 15, GREATEST(rhr + 11, LEAST(80, night_p05 + adj)));

  WITH mb AS (
    SELECT date_trunc('minute', recorded_at) AS m_ts,
           avg(heart_rate)::numeric AS hr_avg,
           avg(COALESCE(accel_mag_mg, 0))::numeric AS accel_avg
    FROM realtime_health
    WHERE user_id=p_user_id AND recorded_at >= p_since AND recorded_at < p_now
      AND heart_rate IS NOT NULL AND heart_rate > 30
    GROUP BY 1
  ),
  smoothed AS (
    SELECT m_ts, accel_avg,
           avg(hr_avg) OVER (ORDER BY m_ts ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) AS hr_smooth
    FROM mb
  ),
  flagged AS (
    SELECT m_ts,
           CASE WHEN hr_smooth < thresh
                 AND (accel_avg IS NULL OR accel_avg < 40) THEN 1 ELSE 0 END AS is_low
    FROM smoothed
  ),
  sustained AS (
    SELECT m_ts,
      SUM(is_low) OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 9 FOLLOWING) AS fwd,
      COUNT(*)    OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 9 FOLLOWING) AS n,
      max(m_ts)   OVER (ORDER BY m_ts ROWS BETWEEN CURRENT ROW AND 9 FOLLOWING) AS last_ts,
      SUM(is_low) OVER (ORDER BY m_ts RANGE BETWEEN CURRENT ROW AND interval '59 minutes' FOLLOWING) AS hr_low,
      COUNT(*)    OVER (ORDER BY m_ts RANGE BETWEEN CURRENT ROW AND interval '59 minutes' FOLLOWING) AS hr_n
    FROM flagged
  )
  SELECT MIN(m_ts) INTO onset
  FROM sustained
  WHERE fwd = 10 AND n = 10 AND last_ts - m_ts <= interval '15 minutes'
    AND hr_n >= 45 AND hr_low >= 0.8 * hr_n;

  RETURN onset;
END;$function$;
