-- ════════════════════════════════════════════════════════════════════════════
--  v139 — Biostate engine FOUNDATION
--  Two tables that every state detector (vibe/arousal, respiration, drunk) reads:
--    1. biostate_config   — per-user tunable knobs (jsonb). Edit live, no redeploy.
--    2. state_truth_log   — ground-truth training set (detected vs corrected + bio snapshot).
--
--  Params seeded from deep-research (dr-20260615-135418-biostate-deep.md) + the
--  calibrated Magic Chatbox ClassifyDrunk constants. THE #1 finding: personalized
--  models hit 95.6% vs 70% generic — so state_truth_log is the foundation, not a feature.
--
--  Convention mirrored from existing tables: RLS on, owner = auth.uid(), plus an
--  anon-read policy for Fabi's user_id (same as realtime_health.lucidride_anon_read_rh)
--  so the VRChat broadcaster + anon clients can read detector output. Detector RPCs
--  are SECURITY DEFINER and bypass RLS on write.
-- ════════════════════════════════════════════════════════════════════════════

-- ── 1. biostate_config ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.biostate_config (
  user_id    uuid PRIMARY KEY,
  updated_at timestamptz NOT NULL DEFAULT now(),
  cfg        jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE public.biostate_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bsc_own       ON public.biostate_config;
DROP POLICY IF EXISTS bsc_anon_read ON public.biostate_config;
CREATE POLICY bsc_own       ON public.biostate_config FOR ALL
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY bsc_anon_read ON public.biostate_config FOR SELECT
  USING (user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);

-- ── 2. state_truth_log ──────────────────────────────────────────────────────
-- One row per correction Fabi makes. detected_* = what the model said,
-- corrected_* = ground truth. Both label (text) and value (numeric) so it fits
-- vibe (label), arousal (0-10), respiration (bpm), drunk (stage 0-4) uniformly.
-- The biometric snapshot is the feature vector at correction time = the training X.
CREATE TABLE IF NOT EXISTS public.state_truth_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL,
  ts              timestamptz NOT NULL DEFAULT now(),
  detector        text NOT NULL CHECK (detector IN ('vibe','arousal','respiration','drunk')),

  detected_state  text,        -- model label  (e.g. "🔥 hyped", "drunk")
  detected_value  numeric,     -- model number (e.g. arousal 7, resp 16, stage 3)
  corrected_state text,        -- truth label
  corrected_value numeric,     -- truth number

  -- biometric snapshot (the training feature vector)
  hr              numeric,
  rmssd           numeric,
  sdnn            numeric,
  pnn50           numeric,
  dfa_alpha1      numeric,
  lf_power        numeric,
  hf_power        numeric,
  lf_hf           numeric,
  total_power     numeric,
  lf_hf_hrc       numeric,     -- HR-corrected LF/HF (research: +26.8% repeatability)
  resp_rate       numeric,
  baevsky_si      numeric,
  hmm_state_id    int,
  activity_state  text,
  motion_flag     boolean,     -- accel confounder: was he moving
  feature_quality numeric,     -- 0..1 window signal quality
  baseline_rmssd  numeric,     -- personal baseline at the time (for ratios)
  baseline_hr     numeric,

  note            text,        -- free text ("3 beers, with food")
  source          text NOT NULL DEFAULT 'manual'   -- 'manual' | 'auto'
);

CREATE INDEX IF NOT EXISTS idx_state_truth_user_det_ts
  ON public.state_truth_log (user_id, detector, ts DESC);

ALTER TABLE public.state_truth_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stl_own       ON public.state_truth_log;
DROP POLICY IF EXISTS stl_anon_read ON public.state_truth_log;
CREATE POLICY stl_own       ON public.state_truth_log FOR ALL
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY stl_anon_read ON public.state_truth_log FOR SELECT
  USING (user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid);

-- ── 3. Seed Fabi's config ────────────────────────────────────────────────────
-- ON CONFLICT DO NOTHING: re-applying the migration never clobbers live tuning.
-- ⚠️ body{} = Widmark inputs; weight_kg/height_cm are PLACEHOLDERS (correct them).
INSERT INTO public.biostate_config (user_id, cfg) VALUES (
  '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  '{
    "version": 1,
    "windows_s":   { "respiration": 60, "arousal": 240, "drunk": 180 },
    "freq_bands":  { "lf": [0.04, 0.15], "hf": [0.15, 0.40], "resp": [0.12, 0.40] },
    "respiration": { "resample_hz": 4, "welch_seg_s": 4, "smooth_pts": 5, "min_bpm": 7.2, "max_bpm": 24 },
    "arousal": {
      "lf_hf_arousal_pct": 30,
      "stress_rmssd_drop_pct": 20,
      "stress_hr_rise_bpm": 10,
      "relaxed_pctile": 95,
      "baseline_ema_alpha": 0.05,
      "hr_correct": true
    },
    "drunk": {
      "rmssd_ratios": [0.91, 0.82, 0.64, 0.55],
      "dfa_alpha1_alcohol_thresh": 0.75,
      "sober_rmssd_fallback": 55,
      "widmark": {
        "drink_grams": { "Light": 10, "Standard": 14, "Strong": 20, "Double": 28 },
        "food_factor": 0.70,
        "elimination_per_hr": 0.015,
        "r_clamp": [0.45, 0.85]
      },
      "body": { "weight_kg": 75, "height_cm": 175, "age": 20, "sex": "male" },
      "hysteresis_s": { "rise_hold": 45, "fall_hold": 150 },
      "gated_by_alcohol_mode": true
    },
    "quality": { "min_beats": 20, "min_coverage_frac": 0.4, "max_ectopic_frac": 0.3 }
  }'::jsonb
) ON CONFLICT (user_id) DO NOTHING;
