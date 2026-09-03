-- migration v119_body_battery_live_server.sql
-- Make Body Battery FULLY server-authoritative + live, so:
--   (a) it never shows 100 "fresh today" — it's the carry-over reservoir minus
--       the day's drain, so 100 is only possible if genuinely earned;
--   (b) ALL the math lives on the server — tuning it needs zero app rebuild. The
--       app (build 37) already reads health_metrics.body_battery via fetchLastScores
--       and displays it; we just keep that column correct + fresh.
--
-- Why it showed 100: today's body_battery column was NULL (nothing wrote it), so
-- the app fell back to its on-device default of 100. Now the server writes it.
--
-- Live value = anchor (reservoir, v118) − intraday drain since wake (from the live
-- realtime_health HR stream the app already pushes). Capped at the anchor, so the
-- tank only goes DOWN through the waking day (minus tiny rest), never refills to 100.

-- Drain points accumulated since today's wake: a base metabolic cost per waking
-- hour + an exertion term (HR above the personal resting floor).
CREATE OR REPLACE FUNCTION public.body_battery_intraday_drain(
  p_user_id uuid, p_at timestamptz DEFAULT now()
)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE
  floor_hr numeric; wake timestamptz; waking_h numeric; bpm_hours numeric;
BEGIN
  SELECT median INTO floor_hr FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  floor_hr := COALESCE(floor_hr, 50);

  SELECT sleep_end INTO wake FROM health_metrics
   WHERE user_id=p_user_id AND metric_date = (p_at AT TIME ZONE 'Europe/Berlin')::date;
  -- fallback if no detected wake yet (or it's in the future): assume a 14h day
  IF wake IS NULL OR wake > p_at THEN wake := p_at - interval '14 hours'; END IF;

  waking_h := GREATEST(0, EXTRACT(epoch FROM (p_at - wake)) / 3600.0);

  -- exertion in bpm-hours: sum of (hr - floor) over readings, ~10s apart.
  SELECT COALESCE(sum(GREATEST(0, heart_rate - floor_hr)), 0) * 10.0 / 3600.0
    INTO bpm_hours
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate > 30
    AND recorded_at >= wake AND recorded_at <= p_at;

  -- 1.2 pts per waking hour (just being up) + 0.12 per bpm-hour of exertion.
  -- Tunable: a sedentary 16h day ≈ 19 + ~light exertion; an active day drains more.
  RETURN round((1.2 * waking_h + 0.12 * COALESCE(bpm_hours,0))::numeric, 1);
END;$f$;

-- Current live tank = anchor − drain, floored at 5, capped at the morning anchor.
CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE anchor numeric; drain numeric;
BEGIN
  anchor := body_battery_anchor_today(p_user_id);
  IF anchor IS NULL THEN RETURN NULL; END IF;
  drain := body_battery_intraday_drain(p_user_id);
  RETURN GREATEST(5, LEAST(anchor, anchor - drain));
END;$f$;

-- Write the live value into today's body_battery column (what the app reads) and
-- return it. NO anchor recompute here — cheap enough to run every few minutes.
CREATE OR REPLACE FUNCTION public.refresh_live_body_battery(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE v numeric;
BEGIN
  v := body_battery_now(p_user_id);
  IF v IS NOT NULL THEN
    UPDATE health_metrics SET body_battery = round(v)
     WHERE user_id=p_user_id AND metric_date = (now() AT TIME ZONE 'Europe/Berlin')::date;
  END IF;
  RETURN v;
END;$f$;

-- App-facing (build 37 calls this on wake/foreground): refresh the anchor too,
-- then write + return the live value. Replaces the v118 anchor-only version.
CREATE OR REPLACE FUNCTION public.refresh_body_battery(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
BEGIN
  PERFORM recompute_body_battery(p_user_id, 30);   -- keep the reservoir anchor fresh
  RETURN refresh_live_body_battery(p_user_id);
END;$f$;

COMMENT ON FUNCTION public.body_battery_now IS
'v119 live Body Battery = reservoir anchor (v118, carry-over) minus intraday drain since wake (base metabolic + HR-exertion from realtime_health). Capped at the anchor so 100 is impossible unless the morning tank was already ~100. Fully server-side; app just displays the body_battery column.';
