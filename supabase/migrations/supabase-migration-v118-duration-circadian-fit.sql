-- migration v118_duration_circadian_fit.sql
-- Smart Alarm — Module 4 tuning: stop over-prescribing sleep for Fabi.
--
-- Problem (Fabi, 2026-06-07): target_sleep_duration suggested 9.5h =
--   base 8.0 + 1.0 debt + 0.5 "illness". Two faults for HIS physiology:
--   1. The "illness" +0.5 fired on yesterday's elevated resting HR (57 vs ~51
--      median) — but that bump was the ALCOHOL hangover, not sickness. Misread.
--   2. His own 90d data shows oversleeping past ~8.5h causes circadian-drift
--      grogginess (he felt wrecked today partly from this). Repaying 6h of debt
--      in one 9.5h night backfires — debt should clear over several nights at
--      his sweet spot, not one mega-night.
--
-- Fixes:
--   * Illness delta suppressed when the prior night was an alcohol night
--     (alcohol_impact stamp OR detect_overnight_alcohol). Hangover != illness.
--   * Debt contribution capped at +0.5 (was +1.0) — gentle, multi-night repay.
--   * Upper clamp tightened to base+0.75 (was base+2), matching his data that
--     >~8.75h is counterproductive for him.

CREATE OR REPLACE FUNCTION public.target_sleep_duration(
  p_user_id uuid, p_for_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date + 1
)
RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_illness numeric, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE base numeric; debt numeric; ystrain numeric; strainbase numeric;
        yrhr numeric; rhrmed numeric; yalc numeric; was_alcohol boolean;
        v_last date; dd numeric; ds numeric; di numeric; parts text;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- Debt: gentle. Repay over multiple nights at his sweet spot, not one big night.
  debt := compute_sleep_debt(p_user_id);
  dd := LEAST(0.5, 0.25 * debt);

  -- Read the MOST RECENT completed night (not CURRENT_DATE-1, which lags a day
  -- when the plan is computed in the evening after today's recompute). This is
  -- the bug that read the alcohol night's RHR instead of last night's recovered one.
  SELECT metric_date, resting_hr, strain_score, alcohol_impact
    INTO v_last, yrhr, ystrain, yalc
    FROM health_metrics
   WHERE user_id=p_user_id AND sleep_hours > 0
   ORDER BY metric_date DESC LIMIT 1;

  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  ds := CASE WHEN ystrain IS NOT NULL AND strainbase IS NOT NULL AND ystrain > strainbase*1.15
             THEN 0.3 ELSE 0 END;

  -- Was the most recent night an alcohol night? Then an elevated RHR is a
  -- hangover, not illness — do NOT prescribe extra sleep for it.
  was_alcohol := COALESCE(yalc,0) >= 1;
  IF NOT was_alcohol AND v_last IS NOT NULL THEN
    BEGIN
      was_alcohol := detect_overnight_alcohol(p_user_id, v_last, 'Europe/Berlin');
    EXCEPTION WHEN OTHERS THEN was_alcohol := false;
    END;
  END IF;

  SELECT median INTO rhrmed FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  di := CASE WHEN yrhr IS NOT NULL AND rhrmed IS NOT NULL AND yrhr > rhrmed + 3 AND NOT was_alcohol
             THEN 0.5 ELSE 0 END;

  -- Clamp tightened: never push him past base+0.75 — his data says oversleeping
  -- (circadian drift) makes him groggier, not more rested.
  target_h := ROUND(LEAST(GREATEST(base + dd + ds + di, base - 0.5), base + 0.75), 2);
  base_h := base; d_debt := ROUND(dd,2); d_strain := ds; d_illness := di;

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || round(dd,1) || ' debt'; END IF;
  IF ds > 0 THEN parts := parts || ' +0.3 high strain'; END IF;
  IF di > 0 THEN parts := parts || ' +0.5 illness signs'; END IF;
  IF was_alcohol AND yrhr IS NOT NULL AND rhrmed IS NOT NULL AND yrhr > rhrmed + 3 THEN
    parts := parts || ' (skipped illness bump — that was the alcohol)';
  END IF;
  note := parts || ' = aim for ' || target_h || 'h';
  RETURN NEXT;
END;$f$;

COMMENT ON FUNCTION public.target_sleep_duration IS
'v118 smart-alarm Module 4: tonight target = personal optimum + gentle debt (cap +0.5) + strain, illness suppressed on alcohol nights, clamped [base-0.5, base+0.75] to respect his oversleeping-backfires circadian sensitivity.';
