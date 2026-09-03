-- migration v110_personalization_spine.sql
--
-- Smart Alarm — Module 1: the personalization spine ("the brain that learns you").
--
-- This is the foundation the whole smart-alarm system plugs into. Every other
-- module (wind-down readiness, wake-window optimizer, duration flex, circadian
-- anchor) asks the same question: "how is Fabi RIGHT NOW vs his OWN normal?"
-- Population averages are explicitly rejected — everything normalizes against
-- his own rolling history.
--
-- Source: deep-research report 2026-06-04 (knowledge_entries 3599a20f), Domain 7
-- (n-of-1 personalization). Methods: robust rolling baselines (median + MAD,
-- resistant to illness/travel outliers), percentile-rank normalization, and
-- Normal-Normal conjugate Bayesian updating of personal scalar parameters.
--
-- Single-user system. Runs in plain SQL/pg_cron, no trained ML.
--
-- Tables:
--   personal_baselines — per (metric, window_days): median, MAD, mean, sd, p10..p90, n
--   personal_priors    — per param: posterior mu + tau2 + n_obs (Bayesian)
-- Functions:
--   compute_personal_baselines(user)        — refresh all baselines (nightly)
--   personal_z(user, metric, value, window)  — robust z = (v-median)/(1.4826*MAD)
--   personal_percentile(user, metric, value, window) — live percentile rank 0-100
--   update_personal_prior(user, param, obs, obs_sd)  — conjugate posterior update
--   seed_personal_priors(user)               — seed population priors once

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Tables
-- ─────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.personal_baselines (
  user_id      uuid    NOT NULL,
  metric       text    NOT NULL,
  window_days  int     NOT NULL,
  median       numeric,
  mad          numeric,
  mean         numeric,
  sd           numeric,
  p10          numeric,
  p25          numeric,
  p50          numeric,
  p75          numeric,
  p90          numeric,
  n_obs        int     NOT NULL DEFAULT 0,
  computed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, metric, window_days)
);

CREATE TABLE IF NOT EXISTS public.personal_priors (
  user_id     uuid NOT NULL,
  param       text NOT NULL,
  mu          numeric NOT NULL,   -- posterior mean (the personalized value)
  tau2        numeric NOT NULL,   -- posterior variance (shrinks as n grows)
  n_obs       int     NOT NULL DEFAULT 0,
  prior_mu    numeric,            -- population seed (for audit/reset)
  prior_tau2  numeric,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, param)
);

ALTER TABLE public.personal_baselines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personal_priors    ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='personal_baselines' AND policyname='own_baselines') THEN
    CREATE POLICY own_baselines ON public.personal_baselines
      USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename='personal_priors' AND policyname='own_priors') THEN
    CREATE POLICY own_priors ON public.personal_priors
      USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
  END IF;
END$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. compute_personal_baselines(user) — robust rolling stats, 30d + 90d
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_personal_baselines(p_user_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  metrics text[] := ARRAY['hrv_avg','resting_hr','sleep_hours','deep_sleep_min',
                          'rem_sleep_min','recovery_score','sleep_score'];
  m   text;
  win int;
  rows_written int := 0;
BEGIN
  FOREACH m IN ARRAY metrics LOOP
    FOREACH win IN ARRAY ARRAY[30,90] LOOP
      EXECUTE format($q$
        WITH d AS (
          SELECT %1$I::numeric AS v
          FROM health_metrics
          WHERE user_id = $1
            AND %1$I IS NOT NULL AND %1$I > 0
            AND metric_date >= CURRENT_DATE - $2
            AND metric_date < CURRENT_DATE
        ),
        s AS (
          SELECT
            percentile_cont(0.5)  WITHIN GROUP (ORDER BY v) AS med,
            avg(v)              AS mean,
            stddev_samp(v)      AS sd,
            count(*)            AS n,
            percentile_cont(0.10) WITHIN GROUP (ORDER BY v) AS p10,
            percentile_cont(0.25) WITHIN GROUP (ORDER BY v) AS p25,
            percentile_cont(0.50) WITHIN GROUP (ORDER BY v) AS p50,
            percentile_cont(0.75) WITHIN GROUP (ORDER BY v) AS p75,
            percentile_cont(0.90) WITHIN GROUP (ORDER BY v) AS p90
          FROM d
        ),
        madc AS (
          SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(v - (SELECT med FROM s))) AS madv
          FROM d
        )
        INSERT INTO personal_baselines
          (user_id, metric, window_days, median, mad, mean, sd, p10,p25,p50,p75,p90, n_obs, computed_at)
        SELECT $1, %2$L, $2, s.med, madc.madv, s.mean, s.sd, s.p10,s.p25,s.p50,s.p75,s.p90,
               COALESCE(s.n,0), now()
        FROM s, madc
        ON CONFLICT (user_id, metric, window_days) DO UPDATE SET
          median=EXCLUDED.median, mad=EXCLUDED.mad, mean=EXCLUDED.mean, sd=EXCLUDED.sd,
          p10=EXCLUDED.p10, p25=EXCLUDED.p25, p50=EXCLUDED.p50, p75=EXCLUDED.p75, p90=EXCLUDED.p90,
          n_obs=EXCLUDED.n_obs, computed_at=now()
      $q$, m, m) USING p_user_id, win;
      rows_written := rows_written + 1;
    END LOOP;
  END LOOP;
  RETURN rows_written;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. personal_z(user, metric, value, window) — robust z-score
--    (value - median) / (1.4826 * MAD). Falls back to (value-mean)/sd when
--    MAD = 0 (low spread). NULL if no usable baseline.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.personal_z(
  p_user_id uuid, p_metric text, p_value numeric, p_window_days int DEFAULT 30
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  b personal_baselines%ROWTYPE;
BEGIN
  SELECT * INTO b FROM personal_baselines
  WHERE user_id = p_user_id AND metric = p_metric AND window_days = p_window_days;

  IF NOT FOUND OR p_value IS NULL OR b.n_obs < 3 THEN
    RETURN NULL;
  END IF;

  IF b.mad IS NOT NULL AND b.mad > 0 THEN
    RETURN ROUND(((p_value - b.median) / (1.4826 * b.mad))::numeric, 3);
  ELSIF b.sd IS NOT NULL AND b.sd > 0 THEN
    RETURN ROUND(((p_value - b.mean) / b.sd)::numeric, 3);
  ELSE
    RETURN 0;
  END IF;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. personal_percentile(user, metric, value, window) — live percentile 0-100
--    (midrank: counts below + half ties). NULL if no usable history.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.personal_percentile(
  p_user_id uuid, p_metric text, p_value numeric, p_window_days int DEFAULT 30
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  pct numeric;
  allowed text[] := ARRAY['hrv_avg','resting_hr','sleep_hours','deep_sleep_min',
                          'rem_sleep_min','recovery_score','sleep_score'];
BEGIN
  IF p_value IS NULL OR NOT (p_metric = ANY(allowed)) THEN
    RETURN NULL;   -- metric whitelist guards against SQL injection in dynamic column
  END IF;

  EXECUTE format($q$
    SELECT 100.0 * (
      count(*) FILTER (WHERE %1$I < $2)::numeric +
      0.5 * count(*) FILTER (WHERE %1$I = $2)::numeric
    ) / NULLIF(count(*) FILTER (WHERE %1$I IS NOT NULL AND %1$I > 0), 0)
    FROM health_metrics
    WHERE user_id = $1
      AND metric_date >= CURRENT_DATE - $3
      AND metric_date < CURRENT_DATE
  $q$, p_metric) INTO pct USING p_user_id, p_value, p_window_days;

  RETURN ROUND(pct, 1);
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. update_personal_prior(user, param, obs, obs_sd) — Normal-Normal conjugate
--    tau2_new = 1/(1/tau2 + 1/obs_sd^2);  mu_new = tau2_new*(mu/tau2 + obs/obs_sd^2)
--    Posterior tightens and drifts toward his observations as nights accrue.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_personal_prior(
  p_user_id uuid, p_param text, p_obs numeric, p_obs_sd numeric DEFAULT 1.0
)
RETURNS personal_priors
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  pr personal_priors%ROWTYPE;
  new_tau2 numeric;
  new_mu   numeric;
  v_sd     numeric := GREATEST(COALESCE(p_obs_sd, 1.0), 0.0001);
BEGIN
  SELECT * INTO pr FROM personal_priors WHERE user_id = p_user_id AND param = p_param;
  IF NOT FOUND THEN
    -- no prior yet: treat first observation as the prior (weakly)
    INSERT INTO personal_priors(user_id, param, mu, tau2, n_obs, prior_mu, prior_tau2, updated_at)
    VALUES (p_user_id, p_param, p_obs, v_sd*v_sd, 1, p_obs, v_sd*v_sd, now())
    RETURNING * INTO pr;
    RETURN pr;
  END IF;

  new_tau2 := 1.0 / (1.0/pr.tau2 + 1.0/(v_sd*v_sd));
  new_mu   := new_tau2 * (pr.mu/pr.tau2 + p_obs/(v_sd*v_sd));

  UPDATE personal_priors
  SET mu = new_mu, tau2 = new_tau2, n_obs = pr.n_obs + 1, updated_at = now()
  WHERE user_id = p_user_id AND param = p_param
  RETURNING * INTO pr;
  RETURN pr;
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. seed_personal_priors(user) — seed population priors once (idempotent)
--    optimal_sleep_hours: population prior 8.0h (matches his empirical peak),
--    wide variance so his data can move it. hrv/rhr baselines seed from his
--    own 90d median if available, else population.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.seed_personal_priors(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  hrv_med numeric;
  rhr_med numeric;
BEGIN
  SELECT median INTO hrv_med FROM personal_baselines WHERE user_id=p_user_id AND metric='hrv_avg' AND window_days=90;
  SELECT median INTO rhr_med FROM personal_baselines WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=90;

  INSERT INTO personal_priors(user_id, param, mu, tau2, n_obs, prior_mu, prior_tau2)
  VALUES
    (p_user_id, 'optimal_sleep_hours', 8.0, 1.0, 0, 8.0, 1.0),
    (p_user_id, 'hrv_baseline',  COALESCE(hrv_med, 50), 64.0, 0, COALESCE(hrv_med,50), 64.0),
    (p_user_id, 'rhr_baseline',  COALESCE(rhr_med, 55), 25.0, 0, COALESCE(rhr_med,55), 25.0)
  ON CONFLICT (user_id, param) DO NOTHING;
END;
$function$;

COMMENT ON TABLE public.personal_baselines IS 'v110 smart-alarm spine: per-metric robust rolling baselines (median/MAD/percentiles, 30d+90d). Every sleep module normalizes against these, not population norms.';
COMMENT ON TABLE public.personal_priors IS 'v110 smart-alarm spine: Bayesian-updated personal scalar parameters (Normal-Normal conjugate). Posterior mu = the personalized value; tau2 shrinks as nights accrue.';
