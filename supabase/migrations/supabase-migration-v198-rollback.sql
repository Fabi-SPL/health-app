-- v198 rollback
SELECT cron.unschedule('illness_cusum_today');
SELECT cron.unschedule('recompute_today_noon');
DROP FUNCTION IF EXISTS public.body_battery_at(uuid, timestamptz);

CREATE OR REPLACE FUNCTION public.illness_cusum_ensemble(p_user_id uuid, p_date date)
 RETURNS TABLE(tier text, score numeric, signals jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  k numeric := 0.8; h numeric := 5.0;       -- CuSum slack (0.8σ) + alarm threshold (h=5σ)
  d date; row_hm record;
  -- per-signal CuSum state + persistence counters
  s_rhr numeric:=0; s_rmssd numeric:=0; s_resp numeric:=0; s_pnn numeric:=0; s_skin numeric:=0;
  p_rhr int:=0; p_rmssd int:=0; p_skin int:=0;      -- consecutive-day alarm persistence (mandatory)
  z numeric; bl record;
  a_rhr boolean; a_rmssd boolean; a_resp boolean; a_pnn boolean; a_skin boolean;
  mand_alarms int; mand_persist int; bonus_alarms int; today_multi int;
  v_tier text; v_score numeric; v_sig jsonb; v_note text;
BEGIN
  -- Walk the trailing 16 days to build CuSum state up to p_date.
  FOR d IN SELECT generate_series(p_date - 15, p_date, '1 day')::date LOOP
    SELECT resting_hr, hrv_avg, respiratory_rate, pnn50_avg, skin_temp
      INTO row_hm FROM health_metrics
     WHERE user_id=p_user_id AND metric_date=d AND COALESCE(excluded,false)=false;
    IF row_hm IS NULL THEN CONTINUE; END IF;

    a_rhr:=false; a_rmssd:=false; a_resp:=false; a_pnn:=false; a_skin:=false;

    -- RHR (illness = UP). rsd floored at 1.5 bpm (min detectable change) so a steady signal
    -- can't manufacture huge z from a 1-unit blip. Same pattern for every signal below.
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'resting_hr',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.resting_hr>0 THEN
      z := (row_hm.resting_hr - bl.med)/GREATEST(bl.rsd, 1.5);
      s_rhr := GREATEST(0, s_rhr + z - k); a_rhr := s_rhr > h;
    END IF;
    -- RMSSD (illness = DOWN). TemPredict: the single most load-bearing feature.
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'hrv_avg',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.hrv_avg>0 THEN
      z := (bl.med - row_hm.hrv_avg)/GREATEST(bl.rsd, 3.0);
      s_rmssd := GREATEST(0, s_rmssd + z - k); a_rmssd := s_rmssd > h;
    END IF;
    -- skin_temp (illness = UP) — PROMOTED to mandatory (TemPredict +4.9% AUC).
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'skin_temp',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.skin_temp IS NOT NULL THEN
      z := (row_hm.skin_temp - bl.med)/GREATEST(bl.rsd, 0.15);
      s_skin := GREATEST(0, s_skin + z - k); a_skin := s_skin > h;
    END IF;
    -- Respiratory rate (illness = UP) — DEMOTED to bonus while its baseline
    -- rebuilds from real nights (pre-fix history was a fabricated constant).
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'respiratory_rate',d,74,14);
    IF bl.rsd IS NOT NULL AND row_hm.respiratory_rate>0 THEN
      z := (row_hm.respiratory_rate - bl.med)/GREATEST(bl.rsd, 0.8);
      s_resp := GREATEST(0, s_resp + z - k); a_resp := s_resp > h;
    END IF;
    -- pNN50 bonus (DOWN)
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'pnn50_avg',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.pnn50_avg>0 THEN
      z := (bl.med - row_hm.pnn50_avg)/GREATEST(bl.rsd, 2.0);
      s_pnn := GREATEST(0, s_pnn + z - k); a_pnn := s_pnn > h;
    END IF;

    p_rhr   := CASE WHEN a_rhr THEN p_rhr+1 ELSE 0 END;
    p_rmssd := CASE WHEN a_rmssd THEN p_rmssd+1 ELSE 0 END;
    p_skin  := CASE WHEN a_skin THEN p_skin+1 ELSE 0 END;
  END LOOP;

  mand_alarms  := (a_rhr::int + a_rmssd::int + a_skin::int);
  bonus_alarms := (a_pnn::int + a_resp::int);
  mand_persist := GREATEST(CASE WHEN a_rhr THEN p_rhr ELSE 0 END,
                           CASE WHEN a_rmssd THEN p_rmssd ELSE 0 END,
                           CASE WHEN a_skin THEN p_skin ELSE 0 END);
  today_multi  := mand_alarms + bonus_alarms;
  v_score := round(LEAST(100, 100*(s_rhr+s_rmssd+s_skin)/(3*h*2)), 1);

  IF mand_alarms >= 2 AND mand_persist >= 3 THEN v_tier := 'red';
  ELSIF mand_alarms >= 1 OR today_multi >= 2      THEN v_tier := 'yellow';
  ELSE v_tier := 'green'; END IF;

  v_sig := jsonb_build_object(
    'cusum', jsonb_build_object('rhr',round(s_rhr,2),'rmssd',round(s_rmssd,2),'skin_temp',round(s_skin,2),
                                'resp',round(s_resp,2),'pnn50',round(s_pnn,2)),
    'alarms', jsonb_build_object('rhr',a_rhr,'rmssd',a_rmssd,'skin_temp',a_skin,'resp',a_resp,'pnn50',a_pnn),
    'mandatory_alarms', mand_alarms, 'persistence', mand_persist,
    'tuning', 'v167 TemPredict: mandatory rhr+rmssd+skin, resp demoted to bonus');

  SELECT count(*) INTO mand_alarms FROM illness_ground_truth_labels WHERE user_id=p_user_id;  -- reuse var as episode count
  v_note := CASE WHEN mand_alarms = 0 THEN 'baseline-only — no validated episodes yet'
                 ELSE format('n=%s labeled episodes — directional only', mand_alarms) END;

  UPDATE health_metrics SET illness_v2_score=v_score, illness_v2_tier=v_tier,
         illness_v2_note=v_note, illness_v2_signals=v_sig
   WHERE user_id=p_user_id AND metric_date=p_date;

  tier:=v_tier; score:=v_score; signals:=v_sig; RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.illness_risk_now(p_user_id uuid, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE d date; rhrmed numeric; rhrmad numeric; hrvmed numeric; hrvmad numeric;
  cur_rhr numeric; cur_hrv numeric; cur_alc numeric; prev_rhr numeric; prev_hrv numeric; prev_alc numeric; prev_date date;
  rhr_unreliable boolean; hrv_unreliable boolean;
  cur_rd numeric; cur_hd numeric; prev_rd numeric; prev_hd numeric;
  cur_comb numeric; prev_comb numeric; padj boolean; sustained boolean; spike boolean; escalate boolean;
  risk numeric; level text; note text; was_alc boolean; prev_was_alc boolean;
  -- calibrated 2026-07-10 (finding #5/#23/#26): floor MAD so integer RHR jitter is not multi-sigma,
  -- require BOTH RHR and HRV elevated (min of the two, not the mean), risk banded to match level.
  c_watch constant numeric := 1.75;   -- both signals >=1.75 MAD-units off => "watch"
  c_spike constant numeric := 2.5;    -- one very sharp night => escalate to "elevated"
  c_sust  constant numeric := 1.75;   -- two adjacent nights both >=c_sust => "elevated"
BEGIN
  IF p_date IS NULL THEN SELECT max(metric_date) INTO d FROM health_metrics WHERE user_id=p_user_id AND sleep_hours>0; ELSE d := p_date; END IF;
  SELECT median,mad INTO rhrmed,rhrmad FROM personal_baselines WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  SELECT median,mad INTO hrvmed,hrvmad FROM personal_baselines WHERE user_id=p_user_id AND metric='hrv_avg' AND window_days=30;
  rhrmad:=GREATEST(COALESCE(rhrmad,3),3); hrvmad:=GREATEST(COALESCE(hrvmad,4),4);
  rhrmed:=COALESCE(rhrmed,50); hrvmed:=COALESCE(hrvmed,50.65);

  SELECT resting_hr,hrv_avg,COALESCE(alcohol_impact,0) INTO cur_rhr,cur_hrv,cur_alc FROM health_metrics WHERE user_id=p_user_id AND metric_date=d;
  SELECT resting_hr,hrv_avg,COALESCE(alcohol_impact,0),metric_date INTO prev_rhr,prev_hrv,prev_alc,prev_date
    FROM health_metrics WHERE user_id=p_user_id AND metric_date<d AND sleep_hours>0 ORDER BY metric_date DESC LIMIT 1;

  IF cur_rhr IS NULL OR cur_hrv IS NULL THEN RETURN jsonb_build_object('risk',0,'level','no_data','note','No night to score.'); END IF;

  -- #26: implausible resting readings are data errors, not illness. Zero their contribution.
  rhr_unreliable := (cur_rhr < 30 OR cur_rhr > 85);
  hrv_unreliable := (cur_hrv <= 0 OR cur_hrv > 200);
  IF rhr_unreliable AND hrv_unreliable THEN
    RETURN jsonb_build_object('date',d,'risk',0,'level','no_data','note','Readings out of range tonight — no clean resting signal to score.','rhr',cur_rhr,'hrv',cur_hrv,'sustained',false,'was_alcohol',false);
  END IF;

  was_alc:=(cur_alc>=1);
  IF NOT was_alc THEN BEGIN was_alc:=detect_overnight_alcohol(p_user_id,d,'Europe/Berlin'); EXCEPTION WHEN OTHERS THEN was_alc:=false; END; END IF;
  prev_was_alc:=(prev_alc>=1);

  -- deviations (0 if the signal is unreliable so a garbage reading can neither alarm nor corroborate)
  cur_rd := CASE WHEN rhr_unreliable THEN 0 ELSE GREATEST(0,(cur_rhr-rhrmed)/rhrmad) END;
  cur_hd := CASE WHEN hrv_unreliable THEN 0 ELSE GREATEST(0,(hrvmed-cur_hrv)/hrvmad) END;
  cur_comb := LEAST(cur_rd, cur_hd);          -- BOTH must be elevated (min), not the mean
  IF was_alc THEN cur_comb:=0; END IF;

  IF prev_rhr IS NOT NULL AND prev_hrv IS NOT NULL AND NOT (prev_rhr<30 OR prev_rhr>85) AND NOT (prev_hrv<=0 OR prev_hrv>200) THEN
    prev_rd := GREATEST(0,(prev_rhr-rhrmed)/rhrmad);
    prev_hd := GREATEST(0,(hrvmed-prev_hrv)/hrvmad);
    prev_comb := LEAST(prev_rd, prev_hd);
    IF prev_was_alc THEN prev_comb:=0; END IF;
  ELSE prev_comb:=0; END IF;

  -- #26: only "sustained" if the prior scored night is within 2 calendar days (no wear-gap bridging)
  padj := (prev_date IS NOT NULL AND (d - prev_date) <= 2);
  sustained := (padj AND cur_comb>=c_sust AND prev_comb>=c_sust);
  spike := (cur_comb >= c_spike);
  escalate := (sustained OR spike);

  -- #23: risk is banded to the level so the number can never contradict the label
  IF cur_comb < c_watch THEN
    level:='clear'; risk:=LEAST(24, round(cur_comb*14));
  ELSIF NOT escalate THEN
    level:='watch'; risk:=LEAST(49, GREATEST(25, round(cur_comb*18)));
  ELSE
    level:='elevated'; risk:=LEAST(100, GREATEST(50, round(cur_comb*28)));
  END IF;

  IF was_alc THEN note:='Signals up but that reads as alcohol, not illness. Skipped.';
  ELSIF rhr_unreliable OR hrv_unreliable THEN note:='Could not get a clean resting read tonight (RHR/HRV out of range) — nothing to flag from this one.';
  ELSIF level='clear' THEN note:='All clear. RHR and HRV at your normal.';
  ELSIF level='watch' THEN note:='Something is off tonight (RHR '||round(cur_rhr)||' vs '||round(rhrmed)||', HRV '||round(cur_hrv)||' vs '||round(hrvmed)||'). Could be a hard day or the start of something. Keep an eye.';
  ELSIF spike AND NOT sustained THEN note:='One sharp night — RHR up and HRV down together (RHR '||round(cur_rhr)||' vs '||round(rhrmed)||', HRV '||round(cur_hrv)||' vs '||round(hrvmed)||'). Not a trend yet; if it holds tomorrow, treat it as real.';
  ELSE note:='Two nights of elevated RHR + suppressed HRV, not a blip. Your body may be fighting something. Rest, hydrate, no booze, no hard training.'; END IF;

  RETURN jsonb_build_object('date',d,'risk',risk,'level',level,'note',note,'rhr',cur_rhr,'hrv',cur_hrv,'sustained',sustained,'was_alcohol',was_alc);
END;$function$;

CREATE OR REPLACE FUNCTION public.health_signal_baseline(p_user_id uuid, p_signal text, p_date date, p_win integer, p_embargo integer DEFAULT 0)
 RETURNS TABLE(med numeric, rsd numeric, n integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE m numeric; mad numeric; cnt int;
BEGIN
  EXECUTE format($q$
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v), count(*)
    FROM (SELECT %I AS v FROM health_metrics
          WHERE user_id=$1 AND metric_date < $2 - $4 AND metric_date >= $2 - $3 AND %I > 0
            AND COALESCE(excluded,false)=false) t
  $q$, p_signal, p_signal)
  INTO m, cnt USING p_user_id, p_date, p_win, p_embargo;

  IF m IS NULL THEN RETURN; END IF;

  EXECUTE format($q$
    SELECT 1.4826 * percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(%I - $5))
    FROM health_metrics
    WHERE user_id=$1 AND metric_date < $2 - $4 AND metric_date >= $2 - $3 AND %I > 0
      AND COALESCE(excluded,false)=false
  $q$, p_signal, p_signal)
  INTO mad USING p_user_id, p_date, p_win, p_embargo, m;

  med := m; rsd := NULLIF(mad,0); n := cnt; RETURN NEXT;
END;$function$
;
