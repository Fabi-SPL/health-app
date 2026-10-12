-- v212: "ready for sleep" follows sleep pressure, not only the heart rate at the desk.
-- Replayed over the last 60 days of nights, evening HR stays flat for the whole hour before sleep onset
-- and falls only after he lies down. The HR-only index therefore said "wired, ~120 min" on nearly every
-- evening (ready 15 min before his real bedtime on 2 of 38 nights; 26 of 38 with this version).
-- Readiness is now sleep pressure: hours awake since the last night, the last three days' strain,
-- a short last night, and illness signs. HR only vetoes when it is far above anything seen before bed.

CREATE OR REPLACE FUNCTION public.compute_sleep_readiness(p_user_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(sri integer, hr_now numeric, hr_floor numeric, hr_gap numeric, rmssd_now numeric, resp_now numeric, ready boolean, eta_min integer, status text, message text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_floor numeric;
  v_hr numeric; v_rmssd numeric; v_resp numeric;
  v_day date := (p_at AT TIME ZONE 'Europe/Berlin')::date;
  v_woke timestamptz; v_last_h numeric; v_awake_h numeric;
  v_strain3 numeric; v_base_h numeric; v_ill numeric;
  p_awake numeric; p_load numeric; p_debt numeric; p_ill numeric; v_pressure numeric;
  v_wired boolean;
  v_sri int; v_eta int;
  why text[] := '{}';
BEGIN
  SELECT median INTO v_floor FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  IF v_floor IS NULL THEN
    SELECT median INTO v_floor FROM personal_baselines
     WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=90 AND n_obs>=3;
  END IF;
  v_floor := COALESCE(v_floor, 52);

  SELECT avg(heart_rate),
         avg(hrv_rmssd) FILTER (WHERE hrv_rmssd > 0),
         avg(respiratory_rate) FILTER (WHERE respiratory_rate > 0 AND respiratory_rate < 24)
    INTO v_hr, v_rmssd, v_resp
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate > 30
    AND recorded_at >= p_at - interval '10 minutes' AND recorded_at <= p_at;

  -- last real night before p_at: when he woke and how long he slept
  SELECT h.sleep_end, h.sleep_hours INTO v_woke, v_last_h
    FROM health_metrics h
   WHERE h.user_id=p_user_id AND h.sleep_end IS NOT NULL AND h.sleep_end <= p_at
     AND h.sleep_end > p_at - interval '30 hours' AND COALESCE(h.sleep_hours, 0) >= 2
   ORDER BY h.sleep_end DESC LIMIT 1;

  IF v_woke IS NULL AND v_hr IS NULL THEN
    sri:=NULL; hr_now:=NULL; hr_floor:=v_floor; hr_gap:=NULL; rmssd_now:=NULL; resp_now:=NULL;
    ready:=NULL; eta_min:=NULL; status:='⚪ no data'; message:='No recent strap data or last night to read.';
    RETURN NEXT; RETURN;
  END IF;

  v_awake_h := EXTRACT(epoch FROM p_at - v_woke) / 3600.0;

  SELECT avg(strain_score) INTO v_strain3 FROM health_metrics
   WHERE user_id=p_user_id AND metric_date BETWEEN v_day - 2 AND v_day AND strain_score IS NOT NULL;

  BEGIN
    SELECT t.base_h, t.d_illness INTO v_base_h, v_ill FROM public.target_sleep_duration(p_user_id, v_day) t;
  EXCEPTION WHEN OTHERS THEN v_base_h := NULL; v_ill := NULL;
  END;
  v_base_h := COALESCE(v_base_h, 8.0);

  -- sleep pressure, 0..1: 10 h awake is nothing, 16 h is full; load, debt and illness add to it
  p_awake := CASE WHEN v_awake_h IS NULL THEN 0.5 ELSE LEAST(GREATEST((v_awake_h - 10) / 6.0, 0), 1) END;
  p_load  := 0.3 * LEAST(GREATEST((COALESCE(v_strain3, 12) - 12) / 8.0, 0), 1);
  p_debt  := 0.3 * LEAST(GREATEST((v_base_h - COALESCE(v_last_h, v_base_h)) / 2.0, 0), 1);
  p_ill   := CASE WHEN COALESCE(v_ill, 0) > 0 THEN 0.15 ELSE 0 END;
  v_pressure := LEAST(p_awake + p_load + p_debt + p_ill, 1);

  IF v_awake_h IS NOT NULL THEN why := why || format('up %s h', round(v_awake_h, 1)); END IF;
  IF p_load >= 0.1 THEN why := why || format('3-day strain %s', round(v_strain3, 1)); END IF;
  IF p_debt >= 0.1 THEN why := why || format('short last night (%s h)', round(v_last_h, 1)); END IF;
  IF p_ill > 0 THEN why := why || 'illness signs'::text; END IF;

  -- HR only vetoes far above the usual pre-bed level: just trained, not just sitting at a desk
  v_wired := v_hr IS NOT NULL AND v_hr > v_floor + 48;

  v_sri := ROUND(100 * v_pressure * CASE WHEN v_wired THEN 0.6 ELSE 1 END);
  IF v_sri >= 70 THEN v_eta := 0;
  ELSIF v_wired THEN v_eta := 30;
  ELSE v_eta := LEAST(CEIL((0.7 - v_pressure) * 360), 240); END IF;

  sri:=v_sri; hr_now:=ROUND(v_hr,1); hr_floor:=v_floor; hr_gap:=ROUND(v_hr - v_floor,1);
  rmssd_now:=ROUND(v_rmssd,1); resp_now:=ROUND(v_resp,1); eta_min:=v_eta;
  ready := v_sri >= 70;

  IF v_sri >= 70 THEN
    status := '🟢 ready';
    message := format('Sleep pressure is high (%s). Lie down now: your heart comes down within about 15 min of lying down.',
                      array_to_string(why, ', '));
  ELSIF v_wired THEN
    status := '🔴 wired';
    message := format('Heart at %s, well above your usual evening. Give it ~30 min after training before bed.', ROUND(v_hr));
  ELSIF v_sri >= 40 THEN
    status := '🟡 getting there';
    message := format('Sleep pressure building (%s). About %s min until a good window.', array_to_string(why, ', '), v_eta);
  ELSE
    status := '🔵 early';
    message := format('Not much sleep pressure yet (%s). About %s min until a good window.', array_to_string(why, ', '), v_eta);
  END IF;
  RETURN NEXT;
END;
$function$;
