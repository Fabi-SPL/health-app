-- v194 rollback: live definitions before 2026-10-08

CREATE OR REPLACE FUNCTION public.body_battery_intraday_drain(p_user_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  floor_hr numeric; wake timestamptz; waking_h numeric; bpm_hours numeric;
BEGIN
  SELECT median INTO floor_hr FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3;
  floor_hr := COALESCE(floor_hr, 50);

  SELECT sleep_end INTO wake FROM health_metrics
   WHERE user_id=p_user_id AND metric_date = (p_at AT TIME ZONE 'Europe/Berlin')::date;
  -- fallback if no detected wake yet (or it's in the future): assume a 14h day
  IF wake IS NULL OR wake > p_at THEN wake := p_at - interval '14 hours'; END IF;

  waking_h := GREATEST(0, EXTRACT(epoch FROM (p_at - wake)) / 3600.0);

  -- exertion in bpm-hours: sum of (hr - floor) over readings, ~10s apart.
  SELECT COALESCE(sum(GREATEST(0, heart_rate - floor_hr)), 0) * 10.0 / 3600.0
    INTO bpm_hours
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate > 30
    AND recorded_at >= wake AND recorded_at <= p_at;

  -- 1.2 pts per waking hour (just being up) + 0.12 per bpm-hour of exertion.
  -- Tunable: a sedentary 16h day ≈ 19 + ~light exertion; an active day drains more.
  RETURN round((1.2 * waking_h + 0.12 * COALESCE(bpm_hours,0))::numeric, 1);
END;$function$;

CREATE OR REPLACE FUNCTION public.body_load_bpmh(p_user_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  SELECT COALESCE(sum(GREATEST(0, heart_rate
           - COALESCE((SELECT median FROM personal_baselines
                       WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30 AND n_obs>=3), 50)
         )) * 10/3600.0, 0)
  FROM realtime_health
  WHERE user_id=p_user_id AND heart_rate>30 AND recorded_at>=p_from AND recorded_at<=p_to;
$function$;

CREATE OR REPLACE FUNCTION public.cut_status(p_user_id uuid, p_date date DEFAULT ((now() AT TIME ZONE 'Europe/Berlin'::text))::date)
 RETURNS TABLE(tdee integer, bmr integer, active_kcal integer, deficit_target integer, target_intake integer, consumed integer, remaining integer, protein_g numeric, protein_target integer, n_meals integer, last_meal_at timestamp with time zone, headline text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c record; p record; f record; v_active int; v_live int;
BEGIN
  SELECT * INTO c FROM body_daily_calories(p_user_id, p_date);
  SELECT COALESCE(cut_deficit_kcal, 0) AS def, COALESCE(protein_target_g, 0) AS prot
    INTO p FROM user_body_profile WHERE user_id = p_user_id;

  -- body_daily_calories only knows strain accrued SO FAR. Using it raw mid-morning
  -- yields a near-BMR TDEE and an absurdly low target. Project the rest of the day
  -- from the trailing 7-day active average, ratcheting up if today already beat it.
  --
  -- v163: days with zero active_kcal are almost always days the strap was not
  -- recording, not days he lay still for 24h. Exclude them from the mean.
  IF p_date = (now() AT TIME ZONE 'Europe/Berlin')::date THEN
    SELECT count(*) FILTER (WHERE x.active_kcal > 0),
           GREATEST(
             c.active_kcal,
             COALESCE(round(avg(x.active_kcal) FILTER (WHERE x.active_kcal > 0)), 0)
           )
      INTO v_live, v_active
      FROM generate_series(p_date - 7, p_date - 1, '1 day') d
      CROSS JOIN LATERAL body_daily_calories(p_user_id, d::date) x;

    -- Every one of the last 7 days was dead. Nothing to project from; keep
    -- whatever today has actually accrued rather than inventing a number.
    IF v_live = 0 THEN
      v_active := c.active_kcal;
    END IF;
  ELSE
    v_active := c.active_kcal;
  END IF;

  -- kcal lives on the entry, protein lives inside items — summing both across one
  -- lateral join fans the entry total out once per item (215 kcal became 645).
  SELECT COALESCE((SELECT sum(total_kcal) FROM food_entries
                    WHERE user_id = p_user_id
                      AND (captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date), 0)::int AS kcal,
         COALESCE((SELECT sum((i->>'protein_g')::numeric)
                     FROM food_entries fe, jsonb_array_elements(fe.items) i
                    WHERE fe.user_id = p_user_id
                      AND (fe.captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date), 0) AS prot,
         COALESCE((SELECT count(*) FROM food_entries
                    WHERE user_id = p_user_id
                      AND (captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date), 0)::int AS n,
         (SELECT max(captured_at) FROM food_entries
           WHERE user_id = p_user_id
             AND (captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date) AS last_at
    INTO f;

  bmr := c.bmr;
  active_kcal := v_active;
  tdee := c.bmr + v_active;
  deficit_target := p.def;
  target_intake  := GREATEST(tdee - p.def, 1200);   -- never coach below 1200
  consumed       := f.kcal;
  remaining      := target_intake - f.kcal;
  protein_g      := round(f.prot, 1);
  protein_target := p.prot;
  n_meals        := f.n;
  last_meal_at   := f.last_at;

  headline := CASE
    WHEN n_meals = 0            THEN 'Nothing logged yet'
    WHEN remaining < -300       THEN 'Over by ' || abs(remaining) || ' — tomorrow resets it'
    WHEN remaining < 0          THEN 'Just over, ' || abs(remaining) || ' — that is noise'
    WHEN remaining < 250        THEN remaining || ' left — basically done'
    ELSE                             remaining || ' left today'
  END;

  RETURN NEXT;
END $function$;
