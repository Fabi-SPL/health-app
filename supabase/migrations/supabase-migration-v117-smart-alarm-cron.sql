-- migration v117_smart_alarm_cron.sql
-- Smart Alarm — automation layer: materialize the nightly plan + self-running cron.
--
-- The app "downloads" tonight's plan from a single row (smart_alarm_plan) instead
-- of calling the RPC live, so the iOS local-notification scheduler always has a
-- plan even offline. Two cron jobs keep it fresh:
--   * smart_alarm_nightly_learn  (05:35 UTC, AFTER the 05:00 health recompute):
--       recomputes baselines, optimal-sleep prior, and the alcohol priors.
--   * smart_alarm_plan_tonight   (18:00 UTC = 20:00 Berlin): writes tonight's plan.
-- set_drinking_tonight() also refreshes the stored plan immediately, so toggling
-- "drinking tonight" updates what the app downloads in real time.

-- ---------------------------------------------------------------------------
-- 1. The plan the app downloads (one row per wake-morning)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.smart_alarm_plan (
  user_id     uuid    NOT NULL,
  plan_date   date    NOT NULL,            -- the wake morning this plan is for
  plan        jsonb   NOT NULL,
  mode        text,                        -- 'alcohol' | 'normal' (denormalized)
  computed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, plan_date)
);
ALTER TABLE public.smart_alarm_plan ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS smart_alarm_plan_own ON public.smart_alarm_plan;
CREATE POLICY smart_alarm_plan_own ON public.smart_alarm_plan
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- Compute + store tonight's plan (for tomorrow's wake date). Returns the plan.
CREATE OR REPLACE FUNCTION public.refresh_tonight_plan(p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE pd date := (now() AT TIME ZONE 'Europe/Berlin')::date + 1; pj jsonb;
BEGIN
  pj := plan_tonight_auto(p_user_id);
  INSERT INTO smart_alarm_plan(user_id, plan_date, plan, mode, computed_at)
  VALUES (p_user_id, pd, pj, pj->>'mode', now())
  ON CONFLICT (user_id, plan_date)
  DO UPDATE SET plan=EXCLUDED.plan, mode=EXCLUDED.mode, computed_at=now();
  RETURN pj;
END;$f$;

-- ---------------------------------------------------------------------------
-- 2. set_drinking_tonight now also refreshes the stored plan immediately
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_drinking_tonight(
  p_user_id uuid,
  p_drinking boolean DEFAULT true,
  p_for_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date + 1
)
RETURNS public.alcohol_flags
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE r public.alcohol_flags;
BEGIN
  INSERT INTO alcohol_flags(user_id, flag_date, manual_drinking)
  VALUES (p_user_id, p_for_date, p_drinking)
  ON CONFLICT (user_id, flag_date)
  DO UPDATE SET manual_drinking = EXCLUDED.manual_drinking, created_at = now()
  RETURNING * INTO r;
  -- if this flag is for the upcoming night, update what the app downloads now
  IF p_for_date = (now() AT TIME ZONE 'Europe/Berlin')::date + 1 THEN
    PERFORM refresh_tonight_plan(p_user_id);
  END IF;
  RETURN r;
END;$f$;

-- ---------------------------------------------------------------------------
-- 3. Nightly learning wrapper (one call the cron fires)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.smart_alarm_learn(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
BEGIN
  PERFORM compute_personal_baselines(p_user_id);
  PERFORM refresh_optimal_sleep_prior(p_user_id);
  PERFORM refresh_alcohol_priors(p_user_id);
END;$f$;

-- ---------------------------------------------------------------------------
-- 4. Schedule the two cron jobs (single-user: his UUID hardcoded)
-- ---------------------------------------------------------------------------
SELECT cron.schedule(
  'smart_alarm_nightly_learn', '35 5 * * *',
  $cron$SELECT public.smart_alarm_learn('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);$cron$
);
SELECT cron.schedule(
  'smart_alarm_plan_tonight', '0 18 * * *',
  $cron$SELECT public.refresh_tonight_plan('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);$cron$
);

COMMENT ON TABLE public.smart_alarm_plan IS
'v117 smart-alarm: materialized nightly plan the app downloads (one row per wake-morning). Written by refresh_tonight_plan (evening cron + on set_drinking_tonight toggle). plan jsonb carries mode/wake-window/backstop/hr_floor/note.';
