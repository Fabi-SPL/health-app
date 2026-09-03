-- ════════════════════════════════════════════════════════════════════════════
--  v146 — biostate_history table  +  15-min pg_cron sampler
--
--  Powers the dashboard's continuous week-graph. A pg_cron job calls biostate_sample()
--  every 15 min; it runs biostate_all_now(persist=true) (so the live biostate_state
--  stays fresh even when the app is closed) and writes ONE denormalized row per sample.
--
--  has_signal = false marks a gap (all three detectors returned unknown/none for a
--  low-quality / no-data window) so the graph can draw gaps honestly instead of
--  interpolating across dead air.
--
--  EXPERIMENTAL like the rest of the engine — every row carries experimental:true and
--  nothing downstream may consume it as ground truth.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. history table (denormalized, one row per sample) ───────────────────────
CREATE TABLE IF NOT EXISTS public.biostate_history (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id       uuid        NOT NULL,
  ts            timestamptz NOT NULL DEFAULT now(),
  -- arousal
  arousal       numeric,
  arousal_band  text,
  arousal_conf  numeric,
  -- drunk
  drunk_stage   int,
  drunk_label   text,
  drunk_conf    numeric,
  drunk_gated   boolean,
  -- respiration
  resp_rate     numeric,
  resp_conf     numeric,
  resp_method   text,
  -- shared context
  hr            numeric,
  rmssd         numeric,
  quality       numeric,
  has_signal    boolean,
  experimental  boolean     NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS idx_biostate_history_user_ts
  ON public.biostate_history(user_id, ts DESC);

ALTER TABLE public.biostate_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bsh_own       ON public.biostate_history;
DROP POLICY IF EXISTS bsh_anon_read ON public.biostate_history;
CREATE POLICY bsh_own       ON public.biostate_history FOR ALL
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY bsh_anon_read ON public.biostate_history FOR SELECT
  USING (user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);

COMMENT ON TABLE public.biostate_history IS
  'EXPERIMENTAL. 15-min samples of all three biostate detectors for the dashboard week-graph. has_signal=false = gap. Do not consume as truth.';

-- ── 2. sampler ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.biostate_sample(
  p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_all    jsonb;
  v_a      jsonb;
  v_d      jsonb;
  v_r      jsonb;
  v_arousal     numeric;
  v_drunk_stage int;
  v_resp        numeric;
  v_hr     numeric;
  v_rmssd  numeric;
  v_q      numeric;
  v_gated  boolean;
  v_has    boolean;
  v_id     bigint;
BEGIN
  -- persist=true: keeps live biostate_state fresh while the app is closed
  v_all := public.biostate_all_now(p_user, now(), true);
  v_a := v_all->'arousal';
  v_d := v_all->'drunk';
  v_r := v_all->'respiration';

  v_arousal     := (v_a->>'arousal')::numeric;
  v_drunk_stage := (v_d->>'stage')::int;
  v_resp        := (v_r->>'resp_rate')::numeric;
  v_gated       := COALESCE((v_d->>'gated')::boolean, false);

  -- shared context: prefer arousal's window features, fall back to drunk's
  v_hr    := COALESCE((v_a->>'hr')::numeric,    (v_d->>'hr')::numeric);
  v_rmssd := COALESCE((v_a->>'rmssd')::numeric, (v_d->>'rmssd')::numeric);
  v_q     := COALESCE((v_a#>>'{quality,score}')::numeric,
                      (v_d#>>'{quality,score}')::numeric,
                      (v_r#>>'{quality,score}')::numeric);

  -- a "signal" exists if arousal or respiration computed, or drunk is actively
  -- detecting (not the trivial gated-sober case)
  v_has := (v_arousal IS NOT NULL)
        OR (v_resp IS NOT NULL)
        OR ((v_d->>'stage') IS NOT NULL AND NOT v_gated);

  INSERT INTO public.biostate_history(
    user_id, ts, arousal, arousal_band, arousal_conf,
    drunk_stage, drunk_label, drunk_conf, drunk_gated,
    resp_rate, resp_conf, resp_method, hr, rmssd, quality, has_signal, experimental)
  VALUES(
    p_user, now(), v_arousal, v_a->>'band', (v_a->>'confidence')::numeric,
    v_drunk_stage, v_d->>'label', (v_d->>'confidence')::numeric, v_gated,
    v_resp, (v_r->>'confidence')::numeric, v_r->>'method',
    v_hr, v_rmssd, v_q, v_has, true)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'experimental', true, 'sampled', true, 'history_id', v_id,
    'ts', now(), 'has_signal', v_has,
    'arousal', v_arousal, 'drunk_stage', v_drunk_stage, 'resp_rate', v_resp);
END $$;
GRANT EXECUTE ON FUNCTION public.biostate_sample(uuid) TO anon, authenticated, service_role;
COMMENT ON FUNCTION public.biostate_sample(uuid) IS
  'EXPERIMENTAL. Samples all three biostate detectors (persist=true) and appends one row to biostate_history. Driven by the biostate_sample_15min pg_cron job.';

-- ── 3. pg_cron: sample every 15 minutes ───────────────────────────────────────
DO $$ BEGIN
  PERFORM cron.unschedule('biostate_sample_15min');
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT cron.schedule(
  'biostate_sample_15min', '*/15 * * * *',
  $job$SELECT public.biostate_sample('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)$job$);
