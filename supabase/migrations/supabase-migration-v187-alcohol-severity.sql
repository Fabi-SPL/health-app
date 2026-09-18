-- v187: assess_overnight_alcohol — the drunk-o-meter under the v153 boolean.
-- detect_overnight_alcohol stays untouched (v184/v185 staging + recompute depend on it).
-- This layer estimates HOW MANY drinks by inverting the published per-drink dose-response:
--   Grosicki 2026 (WHOOP, 5.1M nights, males): +2.4 bpm sleeping RHR and -3.3 ms RMSSD per drink.
--   Pietilä 2018 (first 3h of sleep): low dose normalizes by hour 3, high dose persists all
--   night -> the late-night HR elevation separates ~2 drinks from a heavy night.
--   Altini 2021: illness is near-identical on HR+HRV alone -> the v153 evening-HR-floor
--   discriminator gates confidence, never the estimate itself.

ALTER TABLE health_metrics ADD COLUMN IF NOT EXISTS alcohol_drinks_est numeric;
ALTER TABLE health_metrics ADD COLUMN IF NOT EXISTS alcohol_confidence text;
ALTER TABLE health_metrics ADD COLUMN IF NOT EXISTS alcohol_assessed_at timestamptz;

CREATE OR REPLACE FUNCTION public.assess_overnight_alcohol(
  p_user_id uuid, p_target_date date, p_user_tz text DEFAULT 'Europe/Berlin'
) RETURNS jsonb
 LANGUAGE plpgsql STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  core_start timestamptz := ((p_target_date - 1)::text || ' 22:00:00')::timestamp AT TIME ZONE p_user_tz;
  core_end   timestamptz := (p_target_date::text       || ' 07:00:00')::timestamp AT TIME ZONE p_user_tz;
  eve_start  timestamptz := ((p_target_date - 1)::text || ' 21:00:00')::timestamp AT TIME ZONE p_user_tz;
  eve_end    timestamptz := (p_target_date::text       || ' 01:00:00')::timestamp AT TIME ZONE p_user_tz;
  detected   boolean;
  manual     boolean;
  asleep_min bigint;
  avg_hr     numeric;
  avg_hrv    numeric;
  eve_min_hr numeric;
  base_rhr   numeric;
  base_hrv   numeric;
  ss         timestamptz;
  se         timestamptz;
  late_hr    numeric;
  delta_hr   numeric;
  delta_hrv  numeric;
  est_hr     numeric;
  est_hrv    numeric;
  est        numeric;
  late_elev  numeric;
  conf       text;
  note       text := NULL;
BEGIN
  SELECT detect_overnight_alcohol(p_user_id, p_target_date, p_user_tz) INTO detected;
  SELECT EXISTS (SELECT 1 FROM alcohol_flags af
                 WHERE af.user_id = p_user_id AND af.flag_date = p_target_date AND af.manual_drinking)
    INTO manual;

  IF NOT detected AND NOT manual THEN
    RETURN jsonb_build_object('detected', false, 'manual', false, 'drinks_est', NULL, 'confidence', NULL);
  END IF;

  SELECT count(DISTINCT date_trunc('minute', recorded_at)), AVG(heart_rate), AVG(hrv_rmssd)
    INTO asleep_min, avg_hr, avg_hrv
  FROM realtime_health
  WHERE user_id = p_user_id AND recorded_at >= core_start AND recorded_at < core_end
    AND heart_rate IS NOT NULL AND heart_rate > 30
    AND sleep_stage IS NOT NULL AND sleep_stage <> 'awake';

  SELECT MIN(heart_rate) INTO eve_min_hr
  FROM realtime_health
  WHERE user_id = p_user_id AND recorded_at >= eve_start AND recorded_at < eve_end
    AND heart_rate IS NOT NULL AND heart_rate > 30;

  -- Same de-polluted sober baseline as v153.
  SELECT COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY resting_hr) FILTER (WHERE resting_hr IS NOT NULL), 50),
         COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_avg)    FILTER (WHERE hrv_avg    IS NOT NULL), 50)
    INTO base_rhr, base_hrv
  FROM health_metrics hm
  WHERE hm.user_id = p_user_id
    AND hm.metric_date < p_target_date AND hm.metric_date >= p_target_date - 21
    AND COALESCE(hm.excluded, false) = false AND hm.alcohol_impact IS NULL
    AND NOT EXISTS (SELECT 1 FROM alcohol_flags af
                    WHERE af.user_id = p_user_id AND af.flag_date = hm.metric_date AND af.manual_drinking);

  IF asleep_min IS NULL OR asleep_min < 120 OR avg_hr IS NULL OR avg_hrv IS NULL THEN
    RETURN jsonb_build_object('detected', detected, 'manual', manual,
      'drinks_est', CASE WHEN manual THEN 1.0 ELSE NULL END,
      'confidence', 'low', 'note', 'insufficient asleep data');
  END IF;

  delta_hr  := GREATEST(avg_hr - base_rhr, 0);
  delta_hrv := GREATEST(base_hrv - avg_hrv, 0);
  est_hr  := delta_hr  / 2.4;   -- Grosicki males: +2.4 bpm per drink
  est_hrv := delta_hrv / 3.3;   -- Grosicki males: -3.3 ms RMSSD per drink
  est := (est_hr + est_hrv) / 2.0;

  -- Pietilä persistence check: last 2h of the sleep window still elevated -> heavy night.
  SELECT o_sleep_start, o_sleep_end INTO ss, se FROM detect_sleep_window(p_user_id, p_target_date);
  IF se IS NOT NULL THEN
    SELECT AVG(heart_rate) INTO late_hr
    FROM realtime_health
    WHERE user_id = p_user_id AND recorded_at >= se - interval '2 hours' AND recorded_at < se
      AND heart_rate IS NOT NULL AND heart_rate > 30
      AND sleep_stage IS NOT NULL AND sleep_stage <> 'awake';
    late_elev := late_hr - base_rhr;
    IF late_elev IS NOT NULL THEN
      IF late_elev > 6 THEN est := GREATEST(est, 4.0);      -- persists all night
      ELSIF late_elev < 3 THEN est := LEAST(est, 3.5);      -- normalized by morning
      END IF;
    END IF;
  END IF;

  est := ROUND(LEAST(GREATEST(est, 0.5), 12.0) * 2) / 2;

  IF detected AND abs(est_hr - est_hrv) <= 2.0 AND asleep_min >= 240 THEN conf := 'high';
  ELSIF detected AND abs(est_hr - est_hrv) > 5.0 THEN
    conf := 'low'; note := 'HR and HRV estimates disagree — staging likely unreliable this night';
    est := ROUND(LEAST(GREATEST(LEAST(est_hr, est_hrv), 0.5), 12.0) * 2) / 2;
  ELSIF detected THEN conf := 'medium';
  ELSE conf := 'low'; note := 'manual flag only, detector silent';
  END IF;

  -- Illness confound gate (Altini 2021): booze holds the evening HR floor up, sickness doesn't.
  IF (eve_min_hr IS NULL OR eve_min_hr <= base_rhr + 18) AND conf <> 'low' THEN
    conf := CASE conf WHEN 'high' THEN 'medium' ELSE 'low' END;
    note := 'evening HR floor not held — could be illness, not alcohol';
  END IF;

  RETURN jsonb_build_object(
    'detected', detected, 'manual', manual,
    'drinks_est', est, 'confidence', conf, 'note', note,
    'signals', jsonb_build_object(
      'delta_rhr_bpm', ROUND(delta_hr,1), 'delta_rmssd_ms', ROUND(delta_hrv,1),
      'est_from_hr', ROUND(est_hr,1), 'est_from_hrv', ROUND(est_hrv,1),
      'late_night_hr_elev', ROUND(late_elev,1), 'asleep_min', asleep_min,
      'eve_min_hr', eve_min_hr, 'base_rhr', base_rhr, 'base_hrv', ROUND(base_hrv,1)));
END;
$function$;

-- Nightly stamp: after morning recompute, write the estimate onto flagged nights.
CREATE OR REPLACE FUNCTION public.stamp_alcohol_assessment(p_user_id uuid)
RETURNS void LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE d date; a jsonb;
BEGIN
  FOR d IN SELECT metric_date FROM health_metrics
           WHERE user_id = p_user_id AND metric_date >= (now() AT TIME ZONE 'Europe/Berlin')::date - 3
             AND (alcohol_impact IS NOT NULL
                  OR EXISTS (SELECT 1 FROM alcohol_flags af WHERE af.user_id = p_user_id
                             AND af.flag_date = metric_date AND af.manual_drinking))
             AND alcohol_assessed_at IS NULL
  LOOP
    a := assess_overnight_alcohol(p_user_id, d);
    UPDATE health_metrics SET
      alcohol_drinks_est = (a->>'drinks_est')::numeric,
      alcohol_confidence = a->>'confidence',
      alcohol_assessed_at = now()
    WHERE user_id = p_user_id AND metric_date = d;
  END LOOP;
END;
$fn$;

SELECT cron.unschedule('alcohol_assess_daily') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='alcohol_assess_daily');
SELECT cron.schedule('alcohol_assess_daily', '30 7 * * *',
  $$SELECT stamp_alcohol_assessment('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)$$);
