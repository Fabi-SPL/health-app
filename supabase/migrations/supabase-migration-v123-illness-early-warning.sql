-- migration v123_illness_early_warning.sql
-- Illness early-warning for Fabi (single-user, bespoke). The pre-existing
-- illness_risk column was a dead stub (always 0). This computes a real risk.
--
-- Reliable signals for HIM = resting_hr (up) + hrv_avg (down) vs 30d personal
-- baseline. Skin temp is null and respiratory_rate is mostly the "24" sentinel,
-- so they are NOT used (textbook wants 4 signals; he has 2 clean ones).
--
-- Key design (avoids false alarms): RHR-up + HRV-down also fires for ALCOHOL
-- and HARD TRAINING, identical to illness. So:
--   * Alcohol nights are excluded (static alcohol_impact flag OR
--     detect_overnight_alcohol signal detection).
--   * "elevated" requires the deviation to be SUSTAINED across 2 nights, since
--     illness persists but a hangover / hard ride is a single night. A single
--     big night caps at "watch" (soft heads-up), never a false "you're sick".
-- Validated on 14 nights: clear on good nights, watch on real off-nights
-- (incl. an unflagged hangover, correctly downgraded), zero false elevated.
-- Applied live via /pg/query (DB is source of truth, this file is the record).

CREATE OR REPLACE FUNCTION public.illness_risk_now(p_user_id uuid, p_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE d date; rhrmed numeric; rhrmad numeric; hrvmed numeric; hrvmad numeric;
  cur_rhr numeric; cur_hrv numeric; cur_alc numeric; prev_rhr numeric; prev_hrv numeric; prev_alc numeric;
  cur_comb numeric; prev_comb numeric; sustained boolean; risk numeric; level text; note text; was_alc boolean; prev_was_alc boolean;
BEGIN
  IF p_date IS NULL THEN SELECT max(metric_date) INTO d FROM health_metrics WHERE user_id=p_user_id AND sleep_hours>0; ELSE d := p_date; END IF;
  SELECT median,mad INTO rhrmed,rhrmad FROM personal_baselines WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  SELECT median,mad INTO hrvmed,hrvmad FROM personal_baselines WHERE user_id=p_user_id AND metric='hrv_avg' AND window_days=30;
  rhrmad:=GREATEST(COALESCE(rhrmad,2),1); hrvmad:=GREATEST(COALESCE(hrvmad,4),1); rhrmed:=COALESCE(rhrmed,51); hrvmed:=COALESCE(hrvmed,51);
  SELECT resting_hr,hrv_avg,COALESCE(alcohol_impact,0) INTO cur_rhr,cur_hrv,cur_alc FROM health_metrics WHERE user_id=p_user_id AND metric_date=d;
  SELECT resting_hr,hrv_avg,COALESCE(alcohol_impact,0) INTO prev_rhr,prev_hrv,prev_alc FROM health_metrics WHERE user_id=p_user_id AND metric_date<d AND sleep_hours>0 ORDER BY metric_date DESC LIMIT 1;
  IF cur_rhr IS NULL OR cur_hrv IS NULL THEN RETURN jsonb_build_object('risk',0,'level','no_data','note','No night to score.'); END IF;
  was_alc:=(cur_alc>=1);
  IF NOT was_alc THEN BEGIN was_alc:=detect_overnight_alcohol(p_user_id,d,'Europe/Berlin'); EXCEPTION WHEN OTHERS THEN was_alc:=false; END; END IF;
  prev_was_alc:=(prev_alc>=1);
  cur_comb:=(GREATEST(0,(cur_rhr-rhrmed)/rhrmad)+GREATEST(0,(hrvmed-cur_hrv)/hrvmad))/2;
  IF was_alc THEN cur_comb:=0; END IF;
  IF prev_rhr IS NOT NULL AND prev_hrv IS NOT NULL THEN prev_comb:=(GREATEST(0,(prev_rhr-rhrmed)/rhrmad)+GREATEST(0,(hrvmed-prev_hrv)/hrvmad))/2; IF prev_was_alc THEN prev_comb:=0; END IF; ELSE prev_comb:=0; END IF;
  sustained:=(cur_comb>=1.0 AND prev_comb>=1.0);
  risk:=LEAST(100, round(cur_comb*28*(CASE WHEN sustained THEN 1.4 ELSE 1.0 END)));
  level:=CASE WHEN risk>=50 AND sustained THEN 'elevated' WHEN risk>=25 THEN 'watch' ELSE 'clear' END;
  IF was_alc THEN note:='Signals up but that reads as alcohol, not illness. Skipped.';
  ELSIF level='clear' THEN note:='All clear. RHR and HRV at your normal.';
  ELSIF level='watch' THEN note:='Something is off tonight (RHR '||round(cur_rhr)||' vs '||round(rhrmed)||', HRV '||round(cur_hrv)||' vs '||round(hrvmed)||'). Could be a hard day or the start of something. Keep an eye.';
  ELSE note:='Two nights of elevated RHR + suppressed HRV, not a blip. Your body is fighting something. Rest, hydrate, no booze, no hard training.'; END IF;
  RETURN jsonb_build_object('date',d,'risk',risk,'level',level,'note',note,'rhr',cur_rhr,'hrv',cur_hrv,'sustained',sustained,'was_alcohol',was_alc);
END;$f$;

COMMENT ON FUNCTION public.illness_risk_now IS
'v123: real illness early-warning from RHR-up + HRV-down vs 30d baseline. Excludes alcohol (flag + detect_overnight_alcohol); elevated requires 2-night sustain so single-night confounds (hangover/training) cap at watch. Replaces the dead illness_risk stub.';
