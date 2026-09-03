-- v136: auto-detect + exclude "broken" nights so a BLE-dropout night never silently
-- shows fake scores or pollutes baselines again. Conservative: a day is excluded ONLY
-- when BOTH hold (near-total sleep-window loss AND no usable sleep), so a legit short
-- night with real coverage is never touched.
--
--   unreliable := core_sleep_rows(01:00-05:00 local) < 200   -- normal nights have 1000-1800
--                 AND (sleep_hours IS NULL OR sleep_hours < 3)
--
-- p_apply=false -> dry run (returns what it WOULD do, mutates nothing).
-- p_apply=true  -> marks excluded=true + nulls headline scores for the flagged day.

CREATE OR REPLACE FUNCTION public.auto_exclude_broken_day(
  p_user_id uuid, p_date date, p_apply boolean DEFAULT false)
RETURNS TABLE(metric_date date, core_rows bigint, sleep_hours numeric,
              would_exclude boolean, reason text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE v_rows bigint; v_sleep numeric; v_excl boolean; v_reason text;
BEGIN
  SELECT count(*) INTO v_rows FROM realtime_health
   WHERE user_id=p_user_id AND heart_rate>20
     AND recorded_at >= ((p_date::text||' 01:00')::timestamp AT TIME ZONE 'Europe/Berlin')
     AND recorded_at <  ((p_date::text||' 05:00')::timestamp AT TIME ZONE 'Europe/Berlin');

  SELECT hm.sleep_hours INTO v_sleep FROM health_metrics hm
   WHERE hm.user_id=p_user_id AND hm.metric_date=p_date;

  v_excl := (v_rows < 200) AND (v_sleep IS NULL OR v_sleep < 3);
  v_reason := CASE WHEN v_excl THEN
    format('Auto-excluded: only %s realtime rows in core sleep 01:00-05:00 (normal 1000-1800) + no usable sleep window. BLE dropout / strap not streaming.', v_rows)
    ELSE NULL END;

  IF p_apply AND v_excl THEN
    UPDATE health_metrics SET
      excluded=true, exclude_reason=v_reason,
      body_battery=NULL, body_battery_anchor=NULL, bb_effective=NULL,
      strain_score=NULL, recovery_score=NULL, readiness_score=NULL
    WHERE user_id=p_user_id AND metric_date=p_date AND excluded=false;
  END IF;

  RETURN QUERY SELECT p_date, v_rows, v_sleep, v_excl, v_reason;
END;$$;

-- nightly cron: runs 05:30 UTC (after 05:00 recompute jobid10), excludes the just-ended
-- night if it was broken. jobid 24.
-- SELECT cron.schedule('auto_exclude_broken_night', '30 5 * * *',
--   $cmd$ SELECT public.auto_exclude_broken_day('372210e5-1dda-41b3-b759-5ff72293b8ff',
--          (now() AT TIME ZONE 'Europe/Berlin')::date, true); $cmd$);
