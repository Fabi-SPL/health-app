-- v132: EVERY data point wired into Body Battery (Fabi: "every single data point implemented,
-- regardless if it has a big impact or not... for the future it might change in combination
-- with other metrics"). Each metric -> a guarded point contribution to the MORNING CHARGE.
-- Null / sentinel / not-yet-collected -> contributes 0, status 'dormant'/'sentinel' (auto-
-- activates when data starts flowing, no code change). The live HR+HRV integral (v129) still
-- drives the moment-to-moment value; this stack modulates the daily ceiling it declines from.
--
-- body_battery_breakdown() is also the transparency view: every metric visibly accounted for,
-- nothing silently ignored. Weights are small + tunable; HRV facets kept light to avoid
-- double-counting the live integral. Total daily adjustment clamped to +/-35.

CREATE OR REPLACE FUNCTION public.body_battery_breakdown(p_user_id uuid, p_date date)
RETURNS TABLE(component text, category text, raw numeric, points numeric, status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
  WITH m AS (SELECT * FROM health_metrics WHERE user_id=p_user_id AND metric_date=p_date)
  -- helper: g(value, points) returns 0 points + 'dormant' when value is null
  SELECT * FROM (
    -- ===== SLEEP ARCHITECTURE (independent of live HRV — real signal) =====
    SELECT 'deep_sleep'::text,'sleep'::text, m.deep_sleep_min::numeric,
      CASE WHEN m.deep_sleep_min IS NULL THEN 0 ELSE GREATEST(-6,LEAST(6,(m.deep_sleep_min-143)/15.0)) END,
      CASE WHEN m.deep_sleep_min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'rem_sleep','sleep', m.rem_sleep_min::numeric,
      CASE WHEN m.rem_sleep_min IS NULL THEN 0 ELSE GREATEST(-4,LEAST(4,(m.rem_sleep_min-136)/18.0)) END,
      CASE WHEN m.rem_sleep_min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'light_sleep','sleep', m.light_sleep_min::numeric, 0,
      CASE WHEN m.light_sleep_min IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'awake_waso','sleep', m.awake_min::numeric,
      CASE WHEN m.awake_min IS NULL THEN 0 WHEN m.awake_min<=15 THEN 1.0 ELSE GREATEST(-8,-(m.awake_min-15)/6.0) END,
      CASE WHEN m.awake_min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_duration','sleep', m.sleep_hours,
      CASE WHEN m.sleep_hours IS NULL THEN 0
           WHEN m.sleep_hours<7 THEN GREATEST(-12,(m.sleep_hours-7)*4)
           WHEN m.sleep_hours>10.5 THEN GREATEST(-9,(10.5-m.sleep_hours)*3)
           ELSE LEAST(1.5,(m.sleep_hours-7)*0.6) END,
      CASE WHEN m.sleep_hours IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_score','sleep', m.sleep_score,
      CASE WHEN m.sleep_score IS NULL THEN 0 ELSE GREATEST(-3,LEAST(3,(m.sleep_score-95)/8.0)) END,
      CASE WHEN m.sleep_score IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_efficiency','sleep', m.sleep_efficiency_pct,
      CASE WHEN m.sleep_efficiency_pct IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.sleep_efficiency_pct-92)/8.0)) END,
      CASE WHEN m.sleep_efficiency_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_fragmentation','sleep', m.sleep_fragmentation::numeric,
      CASE WHEN m.sleep_fragmentation IS NULL THEN 0 ELSE GREATEST(-6,LEAST(1,(30-m.sleep_fragmentation)/12.0)) END,
      CASE WHEN m.sleep_fragmentation IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_performance','sleep', m.sleep_performance_pct,
      CASE WHEN m.sleep_performance_pct IS NULL THEN 0 ELSE GREATEST(-3,LEAST(3,(m.sleep_performance_pct-85)/10.0)) END,
      CASE WHEN m.sleep_performance_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_consistency','sleep', m.sleep_consistency_pct,
      CASE WHEN m.sleep_consistency_pct IS NULL THEN 0 ELSE GREATEST(-3,LEAST(2,(m.sleep_consistency_pct-80)/12.0)) END,
      CASE WHEN m.sleep_consistency_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'sleep_debt','sleep', m.sleep_debt_hours,
      CASE WHEN m.sleep_debt_hours IS NULL THEN 0 ELSE GREATEST(-10,-m.sleep_debt_hours*2) END,
      CASE WHEN m.sleep_debt_hours IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- ===== HRV / AUTONOMIC FACETS (small weights — reinforce, don't double-count integral) =====
    UNION ALL SELECT 'hrv_rmssd','autonomic', m.hrv_avg,
      CASE WHEN m.hrv_avg IS NULL THEN 0 ELSE GREATEST(-3,LEAST(3,(m.hrv_avg-51.5)/12.0)) END,
      CASE WHEN m.hrv_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'hrv_sdnn','autonomic', m.sdnn_avg,
      CASE WHEN m.sdnn_avg IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.sdnn_avg-50)/15.0)) END,
      CASE WHEN m.sdnn_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'hrv_pnn50','autonomic', m.pnn50_avg,
      CASE WHEN m.pnn50_avg IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.pnn50_avg-20)/15.0)) END,
      CASE WHEN m.pnn50_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'hrv_dfa_alpha1','autonomic', m.dfa_alpha1_avg::numeric,
      CASE WHEN m.dfa_alpha1_avg IS NULL THEN 0 ELSE GREATEST(-2,LEAST(2,(m.dfa_alpha1_avg-0.9)*6)) END,
      CASE WHEN m.dfa_alpha1_avg IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'poincare_sd1','autonomic', m.poincare_sd1::numeric,
      CASE WHEN m.poincare_sd1 IS NULL THEN 0 ELSE GREATEST(-1.5,LEAST(1.5,(m.poincare_sd1-40)/20.0)) END,
      CASE WHEN m.poincare_sd1 IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'poincare_sd2','autonomic', m.poincare_sd2::numeric,
      CASE WHEN m.poincare_sd2 IS NULL THEN 0 ELSE GREATEST(-1,LEAST(1,(m.poincare_sd2-55)/25.0)) END,
      CASE WHEN m.poincare_sd2 IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'poincare_ratio','autonomic', m.poincare_ratio::numeric, 0,
      CASE WHEN m.poincare_ratio IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'nocturnal_hr_dip','autonomic', m.nocturnal_hr_dip::numeric,
      -- expect a fractional dip 0..0.4 (e.g. 0.15 = 15%); anything else is a bad unit -> 0
      CASE WHEN m.nocturnal_hr_dip IS NULL OR m.nocturnal_hr_dip<0 OR m.nocturnal_hr_dip>0.4 THEN 0
           ELSE GREATEST(-3,LEAST(3,(m.nocturnal_hr_dip-0.10)*30)) END,
      CASE WHEN m.nocturnal_hr_dip IS NULL THEN 'dormant'
           WHEN m.nocturnal_hr_dip<0 OR m.nocturnal_hr_dip>0.4 THEN 'sentinel' ELSE 'live' END FROM m
    UNION ALL SELECT 'baevsky_stress','autonomic', m.baevsky_stress,
      CASE WHEN m.baevsky_stress IS NULL THEN 0 ELSE GREATEST(-5,LEAST(1,(150-m.baevsky_stress)/40.0)) END,
      CASE WHEN m.baevsky_stress IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'resting_hr','autonomic', m.resting_hr::numeric,
      CASE WHEN m.resting_hr IS NULL THEN 0 ELSE GREATEST(-5,LEAST(4,-(m.resting_hr-50.5)*2)) END,
      CASE WHEN m.resting_hr IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- ===== RECOVERY COMPOSITES (small — these are partly derived from the above) =====
    UNION ALL SELECT 'recovery_score','recovery', m.recovery_score,
      CASE WHEN m.recovery_score IS NULL THEN 0 ELSE GREATEST(-4,LEAST(4,(m.recovery_score-71)/15.0)) END,
      CASE WHEN m.recovery_score IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'readiness_score','recovery', m.readiness_score::numeric, 0,
      CASE WHEN m.readiness_score IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'cognitive_capacity','recovery', m.cognitive_capacity_score, 0,
      CASE WHEN m.cognitive_capacity_score IS NULL THEN 'dormant' ELSE 'info' END FROM m
    -- ===== STRAIN / TRAINING LOAD =====
    UNION ALL SELECT 'strain_stress','load', m.strain_stress,
      CASE WHEN m.strain_stress IS NULL THEN 0 WHEN m.strain_stress>12 THEN GREATEST(-8,-(m.strain_stress-12)*1.2) ELSE 0 END,
      CASE WHEN m.strain_stress IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'strain_physical','load', m.strain_physical, 0,
      CASE WHEN m.strain_physical IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'strain_autonomic','load', m.strain_autonomic, 0,
      CASE WHEN m.strain_autonomic IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'acwr','load', m.acwr,
      CASE WHEN m.acwr IS NULL THEN 0 WHEN m.acwr>1.3 THEN GREATEST(-6,-(m.acwr-1.3)*10)
           WHEN m.acwr<0.8 THEN GREATEST(-3,-(0.8-m.acwr)*5) ELSE 0 END,
      CASE WHEN m.acwr IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'training_monotony','load', m.training_monotony,
      CASE WHEN m.training_monotony IS NULL THEN 0 WHEN m.training_monotony>2 THEN GREATEST(-5,-(m.training_monotony-2)*3) ELSE 0 END,
      CASE WHEN m.training_monotony IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'training_strain','load', m.training_strain, 0,
      CASE WHEN m.training_strain IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'edwards_trimp','load', m.edwards_trimp, 0,
      CASE WHEN m.edwards_trimp IS NULL THEN 'dormant' ELSE 'info' END FROM m
    UNION ALL SELECT 'workout_minutes','load', m.workout_minutes::numeric, 0,
      CASE WHEN m.workout_minutes IS NULL THEN 'dormant' ELSE 'info' END FROM m
    -- ===== CARDIO FITNESS =====
    UNION ALL SELECT 'hrr_1min','fitness', m.hrr_1min::numeric,
      CASE WHEN m.hrr_1min IS NULL THEN 0 ELSE GREATEST(-1,LEAST(1.5,(m.hrr_1min-25)/15.0)) END,
      CASE WHEN m.hrr_1min IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'vo2max','fitness', m.vo2max_estimate::numeric,
      CASE WHEN m.vo2max_estimate IS NULL THEN 0 ELSE GREATEST(-1,LEAST(1,(m.vo2max_estimate-45)/20.0)) END,
      CASE WHEN m.vo2max_estimate IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- ===== ILLNESS / PHYSIOLOGICAL (guard sentinels) =====
    UNION ALL SELECT 'skin_temp','illness', m.skin_temp,
      CASE WHEN m.skin_temp IS NULL THEN 0 ELSE GREATEST(-10,LEAST(0,-(m.skin_temp-35.5)*6)) END,
      CASE WHEN m.skin_temp IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'respiratory_rate','illness', m.respiratory_rate,
      CASE WHEN m.respiratory_rate IS NULL OR m.respiratory_rate=24 THEN 0
           ELSE GREATEST(-5,LEAST(1,-(m.respiratory_rate-15)*1.5)) END,
      CASE WHEN m.respiratory_rate IS NULL THEN 'dormant' WHEN m.respiratory_rate=24 THEN 'sentinel' ELSE 'live' END FROM m
    UNION ALL SELECT 'blood_oxygen','illness', m.blood_oxygen_pct,
      CASE WHEN m.blood_oxygen_pct IS NULL THEN 0 WHEN m.blood_oxygen_pct<95 THEN GREATEST(-8,(m.blood_oxygen_pct-95)*3) ELSE 0 END,
      CASE WHEN m.blood_oxygen_pct IS NULL THEN 'dormant' ELSE 'live' END FROM m
    UNION ALL SELECT 'illness_risk','illness', m.illness_risk::numeric,
      CASE WHEN m.illness_risk IS NULL THEN 0 ELSE GREATEST(-15,-m.illness_risk*15) END,
      CASE WHEN m.illness_risk IS NULL THEN 'dormant' ELSE 'live' END FROM m
    -- ===== BEHAVIORAL =====
    UNION ALL SELECT 'alcohol','behavioral', m.alcohol_impact,
      CASE WHEN m.alcohol_impact IS NULL THEN 0 ELSE GREATEST(-15,-m.alcohol_impact*12) END,
      CASE WHEN m.alcohol_impact IS NULL THEN 'dormant' ELSE 'live' END FROM m
  ) x;
$$;

-- scalar: total daily adjustment to the morning charge, clamped
CREATE OR REPLACE FUNCTION public.body_battery_daily_adjustment(p_user_id uuid, p_date date)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
  SELECT GREATEST(-35, LEAST(35, COALESCE(sum(points),0)))
  FROM body_battery_breakdown(p_user_id, p_date);
$$;
