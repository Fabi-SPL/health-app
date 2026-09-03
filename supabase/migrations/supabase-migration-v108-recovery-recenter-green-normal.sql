-- v108 — Recenter recovery so "your normal" reads recovered (green), not 50.
--
-- Problem (Fabi, 2026-06-02): recovery 46 on a day he felt great + slept 9.3h.
-- Root cause was NOT the cold-start 64.4 baseline (he's on the >=7d personal-
-- percentile path). It was the anchor: v103/v107 map the percentile composite
-- around 50, so a day at the user's OWN median lands at ~50 (yellow). For a
-- healthy 20yo, a typical night is not "50% recovered" — it is recovered.
-- Recovery science treats readiness as deviation BELOW personal baseline; being
-- AT baseline = recovered. Commercial systems (Whoop green >=67) also put a fit
-- user's normal day in green, not at the midpoint.
--
-- Fix: in the personal-percentile path only, move the contrast anchor from 50
-- to 66 (green threshold) and soften the stretch 1.4 -> 1.15 so the range stays
-- bounded. Validated on 12 real days before deploy: today 46->63, normal days
-- ->60s-90s, alcohol night (05-30) 7->31, drunk night (05-23) 5->23, best days
-- ->97-100. Bad nights still flag; the felt range just stops pinning normal at
-- yellow. 100% personal — still pure percentile vs the user's own last-30d.
--
-- UNCHANGED: cold-start (<7d) z-score path (new-user only, Fabi never hits it),
-- HRV/RHR NULL auto-renormalization, percentile window, floor=5, signature,
-- STABLE, search_path pin.

CREATE OR REPLACE FUNCTION public.compute_recovery_score(
  p_user_id uuid,
  p_hrv_avg numeric,
  p_resting_hr integer,
  p_sleep_score numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  history_days int;
  hrv_pct numeric;
  rhr_pct_inv numeric;
  s_score numeric;
  baseline_hrv numeric := 64.4;
  hrv_sd       numeric := 12.0;
  median_rhr   numeric := 58;
  rhr_sd       numeric := 4.75;
  hrv_z numeric;
  rhr_z numeric;
  hrv_component numeric;
  rhr_component numeric;
  sleep_component numeric;
  total_weight numeric := 0;
  weighted_sum numeric := 0;
  raw numeric;
  recovery_anchor numeric := 66;    -- v108: "your normal" = green, not 50
  stretch_k numeric := 1.15;        -- v108: softened from 1.4 (range stays bounded)
  score_floor numeric := 5;
BEGIN
  SELECT COUNT(*) INTO history_days
  FROM health_metrics
  WHERE user_id = p_user_id
    AND hrv_avg IS NOT NULL AND hrv_avg > 0
    AND metric_date >= CURRENT_DATE - 30
    AND metric_date < CURRENT_DATE;

  -- Cold-start path: <7 days of usable history (UNCHANGED — new-user only)
  IF history_days < 7 THEN
    IF p_hrv_avg IS NOT NULL AND p_hrv_avg > 0 THEN
      hrv_z := (p_hrv_avg - baseline_hrv) / hrv_sd;
      hrv_component := sigmoid(hrv_z) * 100;
    ELSE
      hrv_component := 50;
    END IF;

    IF p_resting_hr IS NOT NULL AND p_resting_hr > 0 THEN
      rhr_z := (median_rhr - p_resting_hr) / rhr_sd;
      rhr_component := sigmoid(rhr_z) * 100;
    ELSE
      rhr_component := 50;
    END IF;

    sleep_component := COALESCE(p_sleep_score, 50);

    RETURN ROUND(LEAST(100, GREATEST(score_floor,
      hrv_component * 0.50 + rhr_component * 0.20 + sleep_component * 0.30
    )));
  END IF;

  -- Personal-percentile path (>=7 days history)
  IF p_hrv_avg IS NOT NULL AND p_hrv_avg > 0 THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE hrv_avg < p_hrv_avg)::numeric +
      0.5 * COUNT(*) FILTER (WHERE hrv_avg = p_hrv_avg)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE hrv_avg > 0), 0)
    INTO hrv_pct
    FROM health_metrics
    WHERE user_id = p_user_id
      AND hrv_avg IS NOT NULL AND hrv_avg > 0
      AND metric_date >= CURRENT_DATE - 30
      AND metric_date < CURRENT_DATE;
  ELSE
    hrv_pct := NULL;
  END IF;

  IF p_resting_hr IS NOT NULL AND p_resting_hr > 0 THEN
    SELECT 100.0 * (
      COUNT(*) FILTER (WHERE resting_hr > p_resting_hr)::numeric +
      0.5 * COUNT(*) FILTER (WHERE resting_hr = p_resting_hr)::numeric
    ) / NULLIF(COUNT(*) FILTER (WHERE resting_hr > 0), 0)
    INTO rhr_pct_inv
    FROM health_metrics
    WHERE user_id = p_user_id
      AND resting_hr IS NOT NULL AND resting_hr > 0
      AND metric_date >= CURRENT_DATE - 30
      AND metric_date < CURRENT_DATE;
  ELSE
    rhr_pct_inv := NULL;
  END IF;

  s_score := COALESCE(p_sleep_score, 50);

  IF hrv_pct IS NOT NULL THEN
    weighted_sum := weighted_sum + hrv_pct * 0.55;
    total_weight := total_weight + 0.55;
  END IF;
  IF rhr_pct_inv IS NOT NULL THEN
    weighted_sum := weighted_sum + rhr_pct_inv * 0.30;
    total_weight := total_weight + 0.30;
  END IF;
  weighted_sum := weighted_sum + s_score * 0.15;
  total_weight := total_weight + 0.15;

  IF total_weight = 0 THEN
    RETURN 50;
  END IF;

  raw := weighted_sum / total_weight;

  -- v108: anchor at 66 (green) instead of 50; softened stretch. Floor 5.
  RETURN ROUND(LEAST(100, GREATEST(score_floor, recovery_anchor + (raw - 50) * stretch_k)));
END;
$function$;

COMMENT ON FUNCTION public.compute_recovery_score IS
'v108 (2026-06-02). Recentered recovery: personal-percentile composite (HRV 55% + RHR inv 30% vs own last-30d + absolute sleep 15%) mapped around a 66 anchor (green = your normal) with softened 1.15 stretch, floored at 5. Fixes "normal day reads yellow 50" felt bug while preserving spread (validated: today 46->63, alcohol/drunk nights stay 31/23, best days 97-100). Cold-start (<7d) z-score path unchanged.';
