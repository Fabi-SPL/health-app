-- migration v114_circadian_anchor.sql
-- Smart Alarm — Module 5: the body clock.
--
-- Source: deep-research 2026-06-04 (kb 3599a20f), Domain 5. Estimates his
-- personal circadian low point (CBTmin) and the optimal wake zone that follows
-- it. Full cosinor is in the report; this ships the robust, direction-safe
-- proxy: the hour his heart rate bottoms out across recent nights ≈ CBTmin,
-- and the easy-wake rising-limb is CBTmin + 2h. (Skin-temp is logged too but
-- its phase relationship can invert, so HR nadir is the safer single anchor.)
--
-- Output feeds Module 6 (it warns if a forced wake lands before his natural rise).

CREATE OR REPLACE FUNCTION public.estimate_circadian_anchor(
  p_user_id uuid, p_lookback_days int DEFAULT 21
)
RETURNS TABLE(hr_nadir_hour numeric, cbtmin_hour numeric, optimal_wake_hour numeric, n_samples int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE hrn numeric; nsamp int; ow numeric;
BEGIN
  -- Hour-of-day (Berlin) with the lowest median HR, searched over the
  -- biological night window (22:00-10:00) across recent nights.
  SELECT h, n INTO hrn, nsamp FROM (
    SELECT extract(hour FROM recorded_at AT TIME ZONE 'Europe/Berlin')::int AS h,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY heart_rate) AS m,
           count(*) AS n
    FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate > 30
      AND recorded_at >= now() - make_interval(days => p_lookback_days)
      AND extract(hour FROM recorded_at AT TIME ZONE 'Europe/Berlin')::int IN (22,23,0,1,2,3,4,5,6,7,8,9)
    GROUP BY 1
    HAVING count(*) >= 30
    ORDER BY m ASC
    LIMIT 1
  ) z;

  IF hrn IS NULL THEN RETURN; END IF;

  ow := hrn + 2;
  IF ow >= 24 THEN ow := ow - 24; END IF;

  hr_nadir_hour := hrn;
  cbtmin_hour := hrn;
  optimal_wake_hour := ow;
  n_samples := nsamp;
  RETURN NEXT;
END;$f$;

COMMENT ON FUNCTION public.estimate_circadian_anchor IS
'v114 smart-alarm Module 5: personal circadian anchor from HR nadir (≈CBTmin) over recent nights; optimal easy-wake zone = nadir + 2h (rising limb). Robust proxy for the full cosinor model in the research report.';
