-- v217 rollback: restore compute_sleep_debt and compute_sleep_need as they were before v217 (live defs, 2026-10-13)
CREATE OR REPLACE FUNCTION public.compute_sleep_debt(p_user_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE base numeric; debt numeric; nights int; win int := 7;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- v153 (finding #16): cap each night's deficit at 2h so one very short night
  -- cannot dominate and saturate the debt channel on noise.
  SELECT COALESCE(sum(LEAST(2, GREATEST(0, base - sleep_hours))), 0), count(*)
    INTO debt, nights
  FROM health_metrics
  WHERE user_id=p_user_id
    AND sleep_hours > 0
    AND sleep_complete IS NOT FALSE
    AND COALESCE(excluded, false) = false
    AND metric_date >= CURRENT_DATE - win AND metric_date < CURRENT_DATE;

  IF nights < 3 THEN RETURN NULL; END IF;          -- too little observed to claim a number
  RETURN ROUND(debt * (win::numeric / nights), 2); -- scale the observed nights up to the window
END;$function$
;

CREATE OR REPLACE FUNCTION public.compute_sleep_need(p_user_id uuid, p_date date DEFAULT (((now() AT TIME ZONE 'Europe/Berlin'::text))::date + 1))
 RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_quality numeric, d_circadian numeric, debt_raw numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  base numeric; debt numeric; dd numeric := 0; ds numeric := 0; dq numeric := 0; dc numeric := 0;
  ystrain numeric; strainbase numeric; yhrv numeric; hrvbase numeric;
  yeff numeric; ydeep numeric; ycons numeric; v_last date;
  deepnorm numeric := 105;
  parts text;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- Homeostatic debt: repayment is partial (~25%/night), and the curve saturates
  -- smoothly toward 0.75 instead of clipping there, so the term keeps discriminating
  -- between 4h owed and 14h owed.
  debt := compute_sleep_debt(p_user_id);
  IF debt IS NOT NULL THEN
    dd := round(0.75 * (1 - exp(-debt / 7.0)), 2);
  END IF;

  SELECT metric_date, strain_score, hrv_avg, sleep_efficiency_pct, deep_sleep_min
    INTO v_last, ystrain, yhrv, yeff, ydeep
    FROM health_metrics
   WHERE user_id=p_user_id AND sleep_hours > 0
   ORDER BY metric_date DESC LIMIT 1;

  -- Strain: yesterday's load vs his 14-day baseline. strain_score pegs at Whoop's
  -- 21.0 ceiling on ~46% of days, so this channel is weak by construction; the 0.4
  -- cap keeps a saturated input from dominating.
  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  IF ystrain IS NOT NULL AND strainbase > 0 AND ystrain > strainbase THEN
    ds := ds + LEAST(0.4, 0.4 * ((ystrain / strainbase) - 1));
  END IF;
  hrvbase := COALESCE(
    (SELECT baseline_hrv_avg FROM current_state WHERE user_id=p_user_id),
    (SELECT avg(hrv_avg) FROM health_metrics WHERE user_id=p_user_id AND hrv_avg>0 AND metric_date >= CURRENT_DATE - 14));
  IF yhrv IS NOT NULL AND hrvbase IS NOT NULL AND yhrv < 0.90 * hrvbase THEN ds := ds + 0.15; END IF;
  ds := round(LEAST(0.5, ds), 2);

  IF yeff  IS NOT NULL AND yeff  < 85            THEN dq := dq + LEAST(0.4, 0.4*((85-yeff)/15.0)); END IF;
  IF ydeep IS NOT NULL AND ydeep < deepnorm - 15 THEN dq := dq + 0.15; END IF;
  dq := round(LEAST(0.5, dq), 2);

  -- Circadian: measured off his actual bedtime scatter, not the dead column.
  ycons := sleep_consistency_score(p_user_id, (now() AT TIME ZONE 'Europe/Berlin')::date);
  IF ycons IS NOT NULL AND ycons < 70 THEN
    dc := round(LEAST(0.25, 0.25 * ((70 - ycons) / 40.0)), 2);
  END IF;

  target_h    := round(LEAST(9.5, GREATEST(6.0, base + dd + ds + dq + dc)), 2);
  base_h      := base;  d_debt := dd;  d_strain := ds;  d_quality := dq;  d_circadian := dc;
  debt_raw    := round(debt, 2);

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || dd || ' debt (' || round(debt,1) || 'h owed)'; END IF;
  IF ds > 0 THEN parts := parts || ' +' || ds || ' strain'; END IF;
  IF dq > 0 THEN parts := parts || ' +' || dq || ' quality'; END IF;
  IF dc > 0 THEN parts := parts || ' +' || dc || ' circadian (bedtime scatter)'; END IF;
  IF debt IS NULL THEN parts := parts || ' (debt unknown — too few observed nights)'; END IF;
  note := parts || ' -> aim for ' || target_h || 'h tonight';
  RETURN NEXT;
END;$function$
;
