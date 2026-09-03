-- v178 — a raw sensor write must never be aborted by a derived-state side effect
--
-- Measured symptom: realtime_health coverage averaged 56% of the day over 27 days,
-- best day 81.8%, while the strap was worn continuously and BLE stayed connected.
-- bridge_logs recorded 995 upload_stall events in 7 days, all reason=http_400.
--
-- Root cause, two independent faults in the same trigger chain:
--
--   INSERT realtime_health
--     -> trg_refresh_current_state -> refresh_current_state_from_realtime()
--          wrote NEW.readiness straight into current_state.current_readiness.
--          The iOS default is 'unknown'; the CHECK allows only green/yellow/red.
--          sleep_stage 'light_rem' likewise fails sleep_stage_valid.
--          -> 23514 -> whole INSERT rolls back -> PostgREST 400 -> sample lost.
--     -> trg_spiral_detector -> detect_spiral_state()
--          INSERTed notification_queue (notification_type, payload). Neither column
--          exists; the real names are type and context_data. The handler only caught
--          undefined_table, so the 42703 escaped and killed the INSERT underneath.
--
-- The spiral fault was self-perpetuating: the abort also rolled back the
-- spiral_alerts row whose fired_at drives the 4h cooldown, so the cooldown could
-- never engage. spiral_alerts holds 0 rows for all time.
--
-- Fix in three parts:
--   1. normalise values to what the CHECK constraints actually allow
--   2. correct the notification_queue column names so spiral alerts work
--   3. wrap both trigger bodies so ANY future fault degrades the derived state
--      instead of destroying the measurement. Capture is the product; the derived
--      view is a convenience and must never outrank it.
--
-- Failures land in bridge_logs (key=trigger_failure, one entry per function per
-- 5 min) so this class of fault is never silent again.

CREATE OR REPLACE FUNCTION public.log_trigger_failure(
  p_user uuid, p_fn text, p_sqlstate text, p_msg text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.bridge_logs
    WHERE key = 'trigger_failure'
      AND value LIKE 'fn=' || p_fn || ' %'
      AND created_at > now() - interval '5 minutes'
  ) THEN
    RETURN;
  END IF;
  INSERT INTO public.bridge_logs (user_id, source, category, key, value)
  VALUES (p_user, 'postgres', 'health', 'trigger_failure',
          format('fn=%s sqlstate=%s msg=%s', p_fn, p_sqlstate, left(p_msg, 300)));
EXCEPTION WHEN OTHERS THEN
  RETURN;   -- logging must never be the thing that breaks the write
END $fn$;

CREATE OR REPLACE FUNCTION public.refresh_current_state_from_realtime()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_user UUID := NEW.user_id;
  v_now TIMESTAMPTZ := NEW.recorded_at;

  v_last_15m_start TIMESTAMPTZ := v_now - INTERVAL '15 minutes';
  v_last_1h_start  TIMESTAMPTZ := v_now - INTERVAL '1 hour';
  v_last_7d_start  TIMESTAMPTZ := v_now - INTERVAL '7 days';

  v_cog_15m NUMERIC;
  v_cog_label TEXT;
  v_illness_1h NUMERIC;
  v_baseline_hrv NUMERIC;
  v_baseline_rhr INTEGER;
  v_baseline_rr NUMERIC;

  -- normalised copies: current_state carries CHECK constraints that
  -- realtime_health does not, so out-of-set values become NULL, never fatal
  v_stage TEXT;
  v_readiness TEXT;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.current_state
    WHERE user_id = v_user AND updated_at > v_now - INTERVAL '5 seconds'
  ) THEN
    RETURN NEW;
  END IF;

  v_stage := CASE lower(coalesce(NEW.sleep_stage, ''))
               WHEN 'awake'     THEN 'awake'
               WHEN 'light'     THEN 'light'
               WHEN 'deep'      THEN 'deep'
               WHEN 'rem'       THEN 'rem'
               WHEN 'light_rem' THEN 'light'
               WHEN 'sws'       THEN 'deep'
               ELSE NULL
             END;

  v_readiness := CASE lower(coalesce(NEW.readiness, ''))
                   WHEN 'green'  THEN 'green'
                   WHEN 'yellow' THEN 'yellow'
                   WHEN 'red'    THEN 'red'
                   ELSE NULL
                 END;

  SELECT AVG(cognitive_capacity) INTO v_cog_15m
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_15m_start
    AND cognitive_capacity IS NOT NULL AND cognitive_capacity > 0;

  SELECT cognitive_label INTO v_cog_label
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_15m_start
    AND cognitive_label IS NOT NULL
  GROUP BY cognitive_label ORDER BY COUNT(*) DESC LIMIT 1;

  IF v_cog_label IS NOT NULL AND v_cog_label NOT IN ('Full','Good','Reduced','Low') THEN
    v_cog_label := NULL;
  END IF;

  SELECT MAX(illness_risk) INTO v_illness_1h
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_1h_start
    AND illness_risk IS NOT NULL;

  -- audit #38: resting HR is the LOW of sleeping HR, not its average.
  SELECT AVG(hrv_rmssd),
         (percentile_cont(0.05) WITHIN GROUP (ORDER BY heart_rate))::INTEGER,
         AVG(respiratory_rate)
  INTO v_baseline_hrv, v_baseline_rhr, v_baseline_rr
  FROM public.realtime_health
  WHERE user_id = v_user AND recorded_at >= v_last_7d_start
    AND sleep_stage IN ('deep','rem','light')
    AND hrv_rmssd IS NOT NULL AND hrv_rmssd > 0;

  INSERT INTO public.current_state (
    user_id, updated_at,
    strap_connected, last_ble_sample_at, battery_pct,
    current_hr, current_hrv_rmssd, current_sdnn, current_dfa_alpha1, current_respiratory_rate,
    current_cognitive_capacity, current_cognitive_label, current_readiness,
    current_illness_risk, current_sleep_stage,
    current_hmm_state, current_hmm_state_id,
    baseline_hrv_avg, baseline_resting_hr, baseline_respiratory_rate,
    current_activity_state
  ) VALUES (
    v_user, v_now,
    TRUE, v_now, NEW.battery_pct,
    NEW.heart_rate, NEW.hrv_rmssd, NEW.sdnn, NEW.dfa_alpha1, NEW.respiratory_rate,
    v_cog_15m::INTEGER, v_cog_label, v_readiness,
    v_illness_1h, v_stage,
    NEW.hmm_state, NEW.hmm_state_id,
    v_baseline_hrv, v_baseline_rhr, v_baseline_rr,
    CASE
      WHEN v_stage IN ('deep','rem','light') THEN 'sleeping'
      WHEN NEW.heart_rate > 110 THEN 'active'
      ELSE 'resting'
    END
  )
  ON CONFLICT (user_id) DO UPDATE SET
    updated_at = EXCLUDED.updated_at,
    strap_connected = TRUE,
    last_ble_sample_at = EXCLUDED.last_ble_sample_at,
    battery_pct = EXCLUDED.battery_pct,
    current_hr = EXCLUDED.current_hr,
    current_hrv_rmssd = EXCLUDED.current_hrv_rmssd,
    current_sdnn = COALESCE(EXCLUDED.current_sdnn, current_state.current_sdnn),
    current_dfa_alpha1 = COALESCE(EXCLUDED.current_dfa_alpha1, current_state.current_dfa_alpha1),
    current_respiratory_rate = COALESCE(EXCLUDED.current_respiratory_rate, current_state.current_respiratory_rate),
    current_cognitive_capacity = COALESCE(EXCLUDED.current_cognitive_capacity, current_state.current_cognitive_capacity),
    current_cognitive_label = COALESCE(EXCLUDED.current_cognitive_label, current_state.current_cognitive_label),
    current_readiness = COALESCE(EXCLUDED.current_readiness, current_state.current_readiness),
    current_illness_risk = COALESCE(EXCLUDED.current_illness_risk, current_state.current_illness_risk),
    current_sleep_stage = EXCLUDED.current_sleep_stage,
    current_hmm_state = COALESCE(EXCLUDED.current_hmm_state, current_state.current_hmm_state),
    current_hmm_state_id = COALESCE(EXCLUDED.current_hmm_state_id, current_state.current_hmm_state_id),
    baseline_hrv_avg = COALESCE(EXCLUDED.baseline_hrv_avg, current_state.baseline_hrv_avg),
    baseline_resting_hr = COALESCE(EXCLUDED.baseline_resting_hr, current_state.baseline_resting_hr),
    baseline_respiratory_rate = COALESCE(EXCLUDED.baseline_respiratory_rate, current_state.baseline_respiratory_rate),
    current_activity_state = EXCLUDED.current_activity_state;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  PERFORM public.log_trigger_failure(v_user, 'refresh_current_state_from_realtime',
                                     SQLSTATE, SQLERRM);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.detect_spiral_state()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  baseline_hrv numeric;
  baseline_hr numeric;
  hrv_drop_pct numeric;
  hr_rise_pct numeric;
  last_alert_at timestamptz;
  cooldown_hours int := 4;
  hrv_threshold_pct numeric := 20.0;
  hr_threshold_pct numeric := 15.0;
BEGIN
  IF NEW.current_hrv_rmssd IS NULL OR NEW.current_hr IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.current_hrv_rmssd <= 0 OR NEW.current_hr <= 0 THEN
    RETURN NEW;
  END IF;

  baseline_hrv := COALESCE(NEW.baseline_hrv_avg, 0);
  baseline_hr := COALESCE(NEW.baseline_resting_hr, 0);

  IF baseline_hrv <= 0 OR baseline_hr <= 0 THEN
    RETURN NEW;
  END IF;

  hrv_drop_pct := (baseline_hrv - NEW.current_hrv_rmssd) / baseline_hrv * 100;
  hr_rise_pct := (NEW.current_hr - baseline_hr) / baseline_hr * 100;

  IF hrv_drop_pct < hrv_threshold_pct OR hr_rise_pct < hr_threshold_pct THEN
    RETURN NEW;
  END IF;

  SELECT MAX(fired_at) INTO last_alert_at
  FROM spiral_alerts
  WHERE user_id = NEW.user_id;

  IF last_alert_at IS NOT NULL AND last_alert_at > now() - (cooldown_hours || ' hours')::interval THEN
    RETURN NEW;
  END IF;

  INSERT INTO spiral_alerts (
    user_id, hrv_drop_pct, hr_rise_pct, hmm_state, fired_at
  ) VALUES (
    NEW.user_id,
    round(hrv_drop_pct::numeric, 1),
    round(hr_rise_pct::numeric, 1),
    NEW.current_hmm_state,
    now()
  );

  -- real column names are type and context_data
  INSERT INTO notification_queue (
    user_id, type, title, body, scheduled_for, priority, context_data
  ) VALUES (
    NEW.user_id,
    'spiral_alert',
    'body called the brain',
    format('your HRV has been low for a while (down %s%%, HR up %s%%). want to talk?',
           round(hrv_drop_pct, 0)::text, round(hr_rise_pct, 0)::text),
    now(),
    'high',
    jsonb_build_object(
      'hrv_drop_pct', round(hrv_drop_pct, 1),
      'hr_rise_pct', round(hr_rise_pct, 1),
      'hmm_state', NEW.current_hmm_state,
      'deep_link', 'lucid://mini-lucid/spiral'
    )
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  PERFORM public.log_trigger_failure(NEW.user_id, 'detect_spiral_state',
                                     SQLSTATE, SQLERRM);
  RETURN NEW;
END;
$function$;
