-- migration v118_body_battery_reservoir.sql
-- Body Battery v2 — the TANK. A carry-over reservoir that integrates multi-day
-- state, so it answers "how much can I actually push today" instead of recovery's
-- memoryless "how well did I charge last night".
--
-- The problem (his own data, Jun 8): recovery read 92 but he felt ~40 — because he
-- drank Jun 5-6 (recovery 28/33) and recovery rebounds in one night while the tank
-- does not. Recovery is a charge RATE; this is the fuel GAUGE.
--
-- Two layers:
--   * ANCHOR (this migration, server, nightly): the morning tank level. A reservoir
--     that carries over day-to-day, crashes fast (esp. alcohol), refills slow+capped.
--     Uses ALL daily signals: recovery, sleep duration, deep+rem, alcohol, resting HR,
--     strain_stress.
--   * LIVE (app, on-device): drains the anchor through the day from the live HR stream.
--
-- Model: bb(d) = bb(d-1) + rate * (effective(d) - bb(d-1))
--   rate = 0.55 when effective < bb (crash fast)   |   0.22 when >= (refill slow)
--   effective(d) = recovery, adjusted for the things recovery under-weights for "push":
--     restorative sleep (deep+rem), alcohol residual, short sleep, high stress load,
--     elevated resting HR (illness / not-yet-recovered).

ALTER TABLE public.health_metrics
  ADD COLUMN IF NOT EXISTS body_battery_anchor numeric,   -- morning tank level (reservoir)
  ADD COLUMN IF NOT EXISTS bb_effective         numeric;  -- that day's all-data readiness target

CREATE OR REPLACE FUNCTION public.recompute_body_battery(p_user_id uuid, p_days int DEFAULT 120)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE
  r record; base_rhr numeric; bb numeric := NULL; eff numeric; restorative numeric; n int := 0;
BEGIN
  SELECT median INTO base_rhr FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  base_rhr := COALESCE(base_rhr, 50);

  FOR r IN
    SELECT metric_date, recovery_score, sleep_hours, deep_sleep_min, rem_sleep_min,
           resting_hr, alcohol_impact, strain_stress
    FROM health_metrics
    WHERE user_id=p_user_id AND metric_date >= CURRENT_DATE - p_days
      AND recovery_score IS NOT NULL
    ORDER BY metric_date ASC
  LOOP
    restorative := COALESCE(r.deep_sleep_min,0) + COALESCE(r.rem_sleep_min,0);

    -- all-data readiness target for the day (0..100)
    eff := r.recovery_score
         + GREATEST(-15, LEAST(5, (restorative - 280) / 12.0))                              -- deep+rem vs his ~280 median
         - (CASE WHEN r.alcohol_impact = 1 THEN 12 ELSE 0 END)                              -- alcohol residual
         - (CASE WHEN COALESCE(r.sleep_hours,8) < 7 THEN (7 - r.sleep_hours) * 5 ELSE 0 END) -- short sleep
         - (CASE WHEN COALESCE(r.strain_stress,0) > 12 THEN (r.strain_stress - 12) * 1.2 ELSE 0 END) -- high stress load
         - (CASE WHEN COALESCE(r.resting_hr,base_rhr) > base_rhr + 4
                 THEN (r.resting_hr - (base_rhr + 4)) * 2.5 ELSE 0 END);                     -- elevated RHR (illness/unrecovered)
    eff := GREATEST(0, LEAST(100, eff));

    -- reservoir: carry over, crash fast / refill slow
    IF bb IS NULL THEN
      bb := eff;
    ELSE
      bb := bb + (CASE WHEN eff < bb THEN 0.55 ELSE 0.22 END) * (eff - bb);
    END IF;
    bb := GREATEST(0, LEAST(100, bb));

    UPDATE health_metrics
       SET body_battery_anchor = round(bb::numeric, 1),
           bb_effective        = round(eff::numeric, 1)
     WHERE user_id = p_user_id AND metric_date = r.metric_date;
    n := n + 1;
  END LOOP;
  RETURN n;
END;$f$;

-- Today's anchor (what the app starts the live battery from at wake).
CREATE OR REPLACE FUNCTION public.body_battery_anchor_today(p_user_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
  SELECT body_battery_anchor FROM health_metrics
   WHERE user_id = p_user_id AND body_battery_anchor IS NOT NULL
   ORDER BY metric_date DESC LIMIT 1;
$f$;

-- One call the app makes on wake/foreground: refresh the reservoir (last 30d is
-- plenty to be current) and return today's anchor. Seeds the live on-device battery.
CREATE OR REPLACE FUNCTION public.refresh_body_battery(p_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
BEGIN
  PERFORM recompute_body_battery(p_user_id, 30);
  RETURN body_battery_anchor_today(p_user_id);
END;$f$;

COMMENT ON FUNCTION public.recompute_body_battery IS
'v118 Body Battery v2: carry-over reservoir tank. bb(d)=bb(d-1)+rate*(effective-bb), rate 0.55 down / 0.22 up. effective = recovery adjusted for deep+rem, alcohol, short sleep, stress load, elevated RHR. Answers "how much can I push" vs recovery''s memoryless "last night''s charge".';

-- Wire body-battery recompute into the existing nightly learn job (v117), after
-- baselines/priors so base_rhr is fresh.
CREATE OR REPLACE FUNCTION public.smart_alarm_learn(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
BEGIN
  PERFORM compute_personal_baselines(p_user_id);
  PERFORM refresh_optimal_sleep_prior(p_user_id);
  PERFORM refresh_alcohol_priors(p_user_id);
  PERFORM recompute_body_battery(p_user_id, 120);
END;$f$;
