-- v129: Body Battery = ONE continuous integral of the raw autonomic stream.
-- Kills the daily-anchor formula (recovery + sleep_hours -> points) Fabi rejected.
-- The level now emerges moment-to-moment from raw Whoop HR + HRV:
--   charge_rate(t) = KC*(HRV/HRV_BASE - 1)  -- parasympathetic above baseline = charging
--                  - KS*(HR - HR_CENTER)     -- sympathetic / strain = draining
--                  - LEAK*(bb - SETPOINT)    -- homeostasis: gently returns to neutral
-- Integrated over 5-min buckets of realtime_health. Sleep charges because HRV is
-- genuinely high then (not "8h = points"). A workout drains during, then HRV rebound
-- AFTER charges it back ("relaxed after a ride"). Multi-day patterns emerge for free.
--
-- STATELESS: the leak (half-life ~3.8h) washes out the start value within ~a day, so
-- "now" = integrate the last 36h from an arbitrary start; no stored state, pure raw data.
-- Constants tuned on Fabi's real 10-day data (sim 2026-06-11). Tunable below.

CREATE OR REPLACE FUNCTION public.body_battery_curve(
  p_user_id uuid, p_from timestamptz, p_to timestamptz
) RETURNS TABLE(at timestamptz, value numeric) LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE
  HRV_BASE numeric := 51.5;   -- his 30d HRV median (personal_baselines hrv_avg)
  HR_CENTER numeric := 68;    -- his 24h MEDIAN HR (not sleeping RHR — waking HR is ~75)
  SETP numeric := 55;         -- homeostatic neutral
  KC numeric := 0.30;         -- HRV (recovery) gain
  KS numeric := 0.013;        -- HR (strain) gain
  LEAK numeric := 0.003;      -- return-to-neutral rate (half-life ~3.8h)
  bb numeric := 55; prev timestamptz; r record; dt numeric; ratio numeric; hr_rel numeric; rate numeric;
BEGIN
  prev := p_from;
  FOR r IN
    WITH b AS (
      SELECT date_bin('5 min', recorded_at, p_from) bkt,
             avg(heart_rate) hr,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_rmssd) hrv
      FROM realtime_health
      WHERE user_id=p_user_id AND recorded_at>=p_from AND recorded_at<=p_to
        AND heart_rate>30 AND hrv_rmssd>0
      GROUP BY 1
    )
    SELECT bkt, hr,
           avg(hrv) OVER (ORDER BY bkt ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) hrv_s  -- 3-bucket smooth
    FROM b ORDER BY bkt
  LOOP
    dt := LEAST(15, GREATEST(0, EXTRACT(epoch FROM (r.bkt - prev))/60.0));  -- cap gaps (strap off)
    IF dt = 0 THEN dt := 5; END IF;
    ratio := r.hrv_s / HRV_BASE;
    hr_rel := r.hr - HR_CENTER;
    rate := KC*(ratio - 1) - KS*hr_rel - LEAK*(bb - SETP);
    bb := GREATEST(0, LEAST(100, bb + rate*dt));
    prev := r.bkt;
    at := r.bkt; value := round(bb);
    RETURN NEXT;
  END LOOP;
END;$$;

-- live "now" = integrate the last 36h (start washes out via the leak)
CREATE OR REPLACE FUNCTION public.body_battery_now(p_user_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
  SELECT value FROM body_battery_curve(p_user_id, now() - interval '36 hours', now())
  ORDER BY at DESC LIMIT 1;
$$;

-- 24h chart for a calendar day: 36h warm-up before midnight (washed out), return the day
CREATE OR REPLACE FUNCTION public.body_battery_series(
  p_user_id uuid, p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date
) RETURNS TABLE(at timestamptz, value numeric) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
  SELECT at, value FROM body_battery_curve(
    p_user_id,
    (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin') - interval '36 hours',
    LEAST(now(), ((p_date::text || ' 23:59:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  )
  WHERE at >= (((p_date::text || ' 00:00:00')::timestamp) AT TIME ZONE 'Europe/Berlin')
  ORDER BY at;
$$;

-- app foreground RPC: refresh the column + return the live continuous value (bare numeric)
CREATE OR REPLACE FUNCTION public.refresh_body_battery(p_user_id uuid)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE v numeric;
BEGIN
  v := body_battery_now(p_user_id);
  IF v IS NOT NULL THEN
    UPDATE health_metrics SET body_battery = round(v)
     WHERE user_id=p_user_id AND metric_date = (now() AT TIME ZONE 'Europe/Berlin')::date;
  END IF;
  RETURN v;
END;$$;

-- The anchor-clamp trigger (v127) capped body_battery at the daily anchor. The anchor is
-- gone now, so that cap would wrongly clamp legit continuous values. Remove it. The function
-- already bounds [0,100]; build 40+ no longer writes the column; the */15 cron keeps it fresh.
DROP TRIGGER IF EXISTS trg_clamp_body_battery ON health_metrics;
DROP FUNCTION IF EXISTS public.clamp_body_battery();
