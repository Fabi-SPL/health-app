-- v223 — Workouts: real start and end from heart rate, heart-rate calories, indoor or outside, GPS route, steps.
--
-- Four things were wrong or missing on a workout:
--
--   1. Calories. workout_finish priced a workout at body_load_bpmh x 1.5, the coefficient the DAILY
--      figure (body_daily_calories) was calibrated with. That coefficient prices a beat above resting at
--      1.5 kcal per hour; during exercise one beat above resting costs about 4x that, so a 40 min run
--      came out under 100 kcal. Workouts now use Keytel et al. 2005 (J Sports Sci 23:289,
--      the VO2max form when a VO2max estimate exists), per minute, above 30% of heart-rate reserve.
--      Below that a minute is priced on a straight line from 1.2 x BMR at resting HR up to Keytel at the
--      threshold, so the two meet. Total and active (total minus BMR) are both kept, and the old figure
--      stays in kcal_v174. body_daily_calories is NOT changed here.
--
--   2. Start and end. He starts and stops by hand and forgets. workout_detect_bounds walks out from the
--      logged start and end over the 3-min mean heart rate and keeps going while it stays above 30% of
--      reserve, tolerating 2 minutes below, at most 90 min each way. The result is stored as a
--      suggestion (detected_start, detected_end); workout_apply_detected moves the workout onto it and
--      keeps the logged times, workout_revert_logged undoes it.
--
--   3. Indoor or outside. workout_types.default_environment, workout_sessions.environment.
--      Indoor workouts never store a route.
--
--   4. Route and steps. The app sends the whole route once, at the end (workout_attach_track), plus
--      pedometer steps and distance. Points worse than 25 m accuracy, jumps faster than the type allows
--      and a route that never leaves a 40 m box (GPS drift indoors) do not count as distance.
--      Routes live in workout_routes on this server only and can be deleted.
--
-- Rollback: supabase-migration-v223-rollback.sql (restores the v174 functions and the old kcal).

BEGIN;

ALTER TABLE public.workout_types ADD COLUMN IF NOT EXISTS default_environment text;
UPDATE public.workout_types
   SET default_environment = CASE WHEN key IN ('walk', 'run', 'bike_outdoor') THEN 'outdoor' ELSE 'indoor' END
 WHERE default_environment IS NULL;

ALTER TABLE public.workout_sessions
  ADD COLUMN IF NOT EXISTS environment       text,
  ADD COLUMN IF NOT EXISTS distance_source   text,
  ADD COLUMN IF NOT EXISTS pedometer_km      numeric,
  ADD COLUMN IF NOT EXISTS steps             int,
  ADD COLUMN IF NOT EXISTS elevation_gain_m  numeric,
  ADD COLUMN IF NOT EXISTS detected_start    timestamptz,
  ADD COLUMN IF NOT EXISTS detected_end      timestamptz,
  ADD COLUMN IF NOT EXISTS logged_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS logged_ended_at   timestamptz,
  ADD COLUMN IF NOT EXISTS kcal_active       int,
  ADD COLUMN IF NOT EXISTS kcal_method       text,
  ADD COLUMN IF NOT EXISTS kcal_v174         int;
ALTER TABLE public.workout_sessions DROP CONSTRAINT IF EXISTS workout_sessions_environment_chk;
ALTER TABLE public.workout_sessions ADD CONSTRAINT workout_sessions_environment_chk
  CHECK (environment IS NULL OR environment IN ('indoor', 'outdoor'));

CREATE TABLE IF NOT EXISTS public.workout_routes (
  workout_id       uuid PRIMARY KEY REFERENCES public.workout_sessions(id) ON DELETE CASCADE,
  user_id          uuid NOT NULL,
  points           jsonb NOT NULL,          -- [[epoch_s, lat, lon, alt_m, hacc_m, speed_mps], ...] kept points only
  point_count      int NOT NULL,
  distance_m       numeric,
  elevation_gain_m numeric,
  created_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.workout_routes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS workout_routes_own ON public.workout_routes;
CREATE POLICY workout_routes_own ON public.workout_routes
  FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
GRANT SELECT, DELETE ON public.workout_routes TO authenticated;

-- ── helpers ────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.workout_hr_ref(p_user_id uuid, OUT rest_hr numeric, OUT max_hr numeric, OUT thr_hr numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  -- Same resting HR and max HR the live zones use (workout_live), so a zone means one thing everywhere.
  SELECT r.v, m.v, r.v + 0.30 * (m.v - r.v)
    FROM (SELECT coalesce((SELECT median FROM personal_baselines
                            WHERE user_id = p_user_id AND metric = 'resting_hr' AND window_days = 30 AND n_obs >= 3), 50)::numeric v) r,
         (SELECT (220 - coalesce((SELECT age FROM user_body_profile WHERE user_id = p_user_id), 30))::numeric v) m;
$$;

CREATE OR REPLACE FUNCTION public.workout_minute_hr(p_user_id uuid, p_from timestamptz, p_to timestamptz)
RETURNS TABLE(m timestamptz, hr numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT date_trunc('minute', recorded_at), avg(heart_rate)::numeric
    FROM realtime_health
   WHERE user_id = p_user_id AND heart_rate BETWEEN 30 AND 230
     AND recorded_at >= p_from AND recorded_at < p_to
   GROUP BY 1 ORDER BY 1;
$$;

-- Real start and end: outward from the logged edges while the 3-min mean HR stays above 30% of reserve.
CREATE OR REPLACE FUNCTION public.workout_detect_bounds(p_user_id uuid, p_start timestamptz, p_end timestamptz,
                                                        OUT d_start timestamptz, OUT d_end timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  ref record; ts timestamptz[]; h numeric[]; n int; i int; i0 int; i1 int; below int; last_ok int;
  t0 timestamptz := date_trunc('minute', p_start) - interval '90 min';
  t1 timestamptz := date_trunc('minute', p_end) + interval '91 min';
  active_in int;
BEGIN
  IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN RETURN; END IF;
  SELECT * INTO ref FROM workout_hr_ref(p_user_id);

  -- one slot per minute (missing minutes stay NULL), 3-min centred mean
  SELECT array_agg(g ORDER BY g), array_agg(x.h3 ORDER BY g) INTO ts, h
    FROM generate_series(t0, t1 - interval '1 min', interval '1 min') g
    LEFT JOIN LATERAL (
      SELECT avg(w.hr) h3 FROM workout_minute_hr(p_user_id, g - interval '1 min', g + interval '2 min') w
    ) x ON true;
  n := coalesce(array_length(ts, 1), 0);
  IF n = 0 THEN RETURN; END IF;

  i0 := 91;                                                      -- logged start minute
  i1 := 91 + (extract(epoch FROM date_trunc('minute', p_end) - date_trunc('minute', p_start)) / 60)::int;
  IF i1 > n THEN i1 := n; END IF;

  SELECT count(*) INTO active_in FROM generate_series(i0, i1) k WHERE h[k] >= ref.thr_hr;
  IF active_in < 5 THEN RETURN; END IF;                         -- nothing that reads as exercise

  -- start: if he pressed start before getting going, move forward to the first active minute (max 15 min)
  i := i0;
  IF coalesce(h[i], 0) < ref.thr_hr THEN
    WHILE i < LEAST(i0 + 15, i1) AND coalesce(h[i], 0) < ref.thr_hr LOOP i := i + 1; END LOOP;
    IF coalesce(h[i], 0) < ref.thr_hr THEN i := i0; END IF;
    d_start := ts[i];
  ELSE
    last_ok := i; below := 0;
    WHILE i > 1 LOOP
      i := i - 1;
      IF h[i] IS NULL OR h[i] < ref.thr_hr THEN below := below + 1; ELSE below := 0; last_ok := i; END IF;
      EXIT WHEN below >= 3;
    END LOOP;
    d_start := ts[last_ok];
  END IF;

  -- end: if he stopped late, move back to the last active minute (max 15 min); else walk forward
  i := i1;
  IF coalesce(h[i], 0) < ref.thr_hr THEN
    WHILE i > GREATEST(i1 - 15, i0) AND coalesce(h[i], 0) < ref.thr_hr LOOP i := i - 1; END LOOP;
    IF coalesce(h[i], 0) < ref.thr_hr THEN i := i1; END IF;
    d_end := ts[i] + interval '1 min';
  ELSE
    last_ok := i; below := 0;
    WHILE i < n LOOP
      i := i + 1;
      IF h[i] IS NULL OR h[i] < ref.thr_hr THEN below := below + 1; ELSE below := 0; last_ok := i; END IF;
      EXIT WHEN below >= 3;
    END LOOP;
    d_end := ts[last_ok] + interval '1 min';
  END IF;
END $$;

-- Calories over a window, per minute. Keytel 2005 above the threshold, a ramp from 1.2 x BMR below it.
CREATE OR REPLACE FUNCTION public.workout_energy(p_user_id uuid, p_from timestamptz, p_to timestamptz,
                                                 OUT kcal int, OUT kcal_active int, OUT method text, OUT hr_minutes int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  p record; ref record; vo2 numeric; bmr_min numeric; k_thr numeric; tot numeric := 0; mins int; r record; rate numeric; mean_rate numeric;
  male boolean;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN RETURN; END IF;
  SELECT weight_kg w, height_cm h, age a, sex INTO p FROM user_body_profile WHERE user_id = p_user_id;
  male := coalesce(p.sex, 'male') <> 'female';
  SELECT * INTO ref FROM workout_hr_ref(p_user_id);
  SELECT vo2max_estimate INTO vo2 FROM health_metrics
   WHERE user_id = p_user_id AND vo2max_estimate BETWEEN 25 AND 80 AND metric_date > (p_from AT TIME ZONE 'Europe/Berlin')::date - 30
   ORDER BY metric_date DESC LIMIT 1;
  bmr_min := (10 * coalesce(p.w, 75) + 6.25 * coalesce(p.h, 175) - 5 * coalesce(p.a, 30) + CASE WHEN male THEN 5 ELSE -161 END) / 1440.0;
  method := CASE WHEN vo2 IS NOT NULL THEN 'keytel_vo2max' ELSE 'keytel' END;

  -- Keytel at the threshold, so the ramp below it meets the formula above it
  k_thr := workout_keytel(ref.thr_hr, coalesce(p.w, 75), coalesce(p.a, 30), vo2, male);

  hr_minutes := 0;
  FOR r IN SELECT hr FROM workout_minute_hr(p_user_id, p_from, p_to) LOOP
    hr_minutes := hr_minutes + 1;
    IF r.hr >= ref.thr_hr THEN
      rate := GREATEST(workout_keytel(r.hr, coalesce(p.w, 75), coalesce(p.a, 30), vo2, male), 1.2 * bmr_min);
    ELSE
      rate := 1.2 * bmr_min + (k_thr - 1.2 * bmr_min)
              * LEAST(1, GREATEST(0, (r.hr - ref.rest_hr) / NULLIF(ref.thr_hr - ref.rest_hr, 0)));
    END IF;
    tot := tot + rate;
  END LOOP;

  mins := GREATEST(1, ceil(extract(epoch FROM (p_to - p_from)) / 60.0)::int);
  IF hr_minutes = 0 THEN kcal := NULL; kcal_active := NULL; method := NULL; RETURN; END IF;
  -- minutes with no heart rate (strap gap) get the window's mean rate rather than zero
  mean_rate := tot / hr_minutes;
  tot := tot + mean_rate * GREATEST(0, mins - hr_minutes);
  kcal := round(tot)::int;
  kcal_active := GREATEST(0, round(tot - bmr_min * mins))::int;
END $$;

CREATE OR REPLACE FUNCTION public.workout_keytel(p_hr numeric, p_w numeric, p_a numeric, p_vo2 numeric, p_male boolean)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  -- Keytel LR et al. 2005, J Sports Sci 23(3):289-97. kJ/min -> kcal/min.
  SELECT CASE
    WHEN p_vo2 IS NOT NULL AND p_male     THEN (-95.7735 + 0.634  * p_hr + 0.404 * p_vo2 + 0.394  * p_w + 0.271 * p_a) / 4.184
    WHEN p_vo2 IS NOT NULL                THEN (-59.3954 + 0.45   * p_hr + 0.380 * p_vo2 + 0.103  * p_w + 0.274 * p_a) / 4.184
    WHEN p_male                           THEN (-55.0969 + 0.6309 * p_hr + 0.1988 * p_w + 0.2017 * p_a) / 4.184
    ELSE                                       (-20.4022 + 0.4472 * p_hr - 0.1263 * p_w + 0.074  * p_a) / 4.184
  END;
$$;

-- Haversine metres
CREATE OR REPLACE FUNCTION public.geo_m(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT 2 * 6371000 * asin(sqrt(
    power(sin(radians((lat2 - lat1)::float8) / 2), 2)
    + cos(radians(lat1::float8)) * cos(radians(lat2::float8)) * power(sin(radians((lon2 - lon1)::float8) / 2), 2)))::numeric;
$$;

-- Recompute everything derived from a workout's current window and mirror it into activities.
CREATE OR REPLACE FUNCTION public.workout_recompute(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE s record; t record; e record; b record; v_hr_avg int; v_hr_peak int; v_load numeric; v_weight numeric; v_dur int;
BEGIN
  SELECT * INTO s FROM workout_sessions w WHERE w.id = p_id;
  IF s.id IS NULL OR s.ended_at IS NULL THEN RETURN; END IF;
  SELECT * INTO t FROM workout_types WHERE key = s.type_key;
  v_dur := GREATEST(1, extract(epoch FROM (s.ended_at - s.started_at))::int);

  SELECT round(avg(r.heart_rate))::int, max(r.heart_rate)::int INTO v_hr_avg, v_hr_peak
    FROM realtime_health r
   WHERE r.user_id = s.user_id AND r.heart_rate > 30 AND r.recorded_at >= s.started_at AND r.recorded_at <= s.ended_at;
  v_load := body_load_bpmh(s.user_id, s.started_at, s.ended_at);
  SELECT * INTO e FROM workout_energy(s.user_id, s.started_at, s.ended_at);
  SELECT * INTO b FROM workout_detect_bounds(s.user_id, coalesce(s.logged_started_at, s.started_at), coalesce(s.logged_ended_at, s.ended_at));

  IF e.kcal IS NULL OR e.hr_minutes < GREATEST(3, v_dur / 120) THEN
    -- strap was off for most of it: rebuild from the type's MET and bodyweight, as v174 did
    SELECT weight_kg INTO v_weight FROM user_body_profile WHERE user_id = s.user_id;
    e.kcal := round((t.met_base + t.met_per_load * coalesce(s.load_level, 5)) * coalesce(v_weight, 75) * (v_dur / 3600.0))::int;
    e.kcal_active := round(e.kcal * 0.85)::int;
    e.method := 'met';
  END IF;

  UPDATE workout_sessions w SET
    duration_sec = v_dur, hr_avg = v_hr_avg, hr_peak = v_hr_peak, load_bpmh = v_load,
    kcal = e.kcal, kcal_active = e.kcal_active, kcal_method = e.method,
    kcal_source = CASE WHEN e.method = 'met' THEN 'estimate' ELSE 'hr' END,
    detected_start = b.d_start, detected_end = b.d_end,
    environment = coalesce(w.environment, t.default_environment)
  WHERE w.id = p_id;

  UPDATE activities a SET started_at = s.started_at, ended_at = s.ended_at, hr_avg = v_hr_avg, hr_peak = v_hr_peak,
         metadata = coalesce(a.metadata, '{}'::jsonb) || jsonb_build_object('kcal', e.kcal, 'kcal_active', e.kcal_active,
                    'kcal_method', e.method, 'distance_km', s.distance_km), updated_at = now()
   WHERE a.id = s.activity_id;
END $$;

-- ── RPCs the app calls ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.workout_start(p_type text, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, type_key text, label text, emoji text, started_at timestamp with time zone, tracks_distance boolean, tracks_load boolean)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := coalesce(p_user_id, auth.uid());
  v_id   uuid;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'no user'; END IF;

  SELECT s.id INTO v_id FROM workout_sessions s
   WHERE s.user_id = v_user AND s.ended_at IS NULL
   ORDER BY s.started_at DESC LIMIT 1;

  IF v_id IS NULL THEN
    -- v223: indoor or outside starts from the type's default; the app may change it
    INSERT INTO workout_sessions (user_id, type_key, environment)
    VALUES (v_user, p_type, (SELECT default_environment FROM workout_types WHERE key = p_type))
    RETURNING workout_sessions.id INTO v_id;
  END IF;

  RETURN QUERY
    SELECT s.id, s.type_key, t.label, t.emoji, s.started_at, t.tracks_distance, t.tracks_load
      FROM workout_sessions s JOIN workout_types t ON t.key = s.type_key
     WHERE s.id = v_id;
END $function$;

CREATE OR REPLACE FUNCTION public.workout_finish(p_id uuid, p_distance_km numeric DEFAULT NULL::numeric, p_load integer DEFAULT NULL::integer, p_rpe integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, duration_sec integer, distance_km numeric, kcal integer, kcal_source text, hr_avg integer, hr_peak integer, headline text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s record; t record; v_end timestamptz := now(); v_act uuid; v_kmh numeric; w record;
BEGIN
  SELECT * INTO s FROM workout_sessions ws WHERE ws.id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RAISE EXCEPTION 'not your session'; END IF;
  IF s.ended_at IS NOT NULL THEN v_end := s.ended_at; END IF;
  SELECT * INTO t FROM workout_types WHERE key = s.type_key;

  UPDATE workout_sessions ws SET
    ended_at = v_end,
    distance_km = coalesce(p_distance_km, ws.distance_km),
    distance_source = CASE WHEN p_distance_km IS NOT NULL AND ws.distance_source IS DISTINCT FROM 'gps' THEN 'manual' ELSE ws.distance_source END,
    load_level = coalesce(p_load, ws.load_level),
    rpe = coalesce(p_rpe, ws.rpe),
    notes = coalesce(p_notes, ws.notes),
    kcal_v174 = round(body_load_bpmh(s.user_id, s.started_at, v_end) * 1.5)::int
  WHERE ws.id = p_id;

  IF s.activity_id IS NULL THEN
    -- Mirror into `activities` so the correlation engine sees it alongside sleep, food and mood.
    -- activities.source is constrained to auto|tap|dump|manual; a deliberate start/stop lands as 'manual'
    -- and is told apart by metadata.workout_session_id.
    INSERT INTO activities (user_id, activity_type, display_name, emoji, started_at, ended_at, source,
                            canonical_activity_type, canonical_category, canonical_emoji, metadata)
    VALUES (s.user_id, s.type_key, t.label, t.emoji, s.started_at, v_end, 'manual',
            s.type_key, t.category, t.emoji,
            jsonb_build_object('workout_session_id', p_id, 'distance_km', p_distance_km, 'load_level', p_load, 'rpe', p_rpe))
    RETURNING activities.id INTO v_act;
    UPDATE workout_sessions ws SET activity_id = v_act WHERE ws.id = p_id;
  END IF;

  PERFORM workout_recompute(p_id);
  SELECT * INTO w FROM workout_sessions ws WHERE ws.id = p_id;

  v_kmh := CASE WHEN w.distance_km > 0 AND w.duration_sec >= 60 THEN round(w.distance_km / (w.duration_sec / 3600.0), 1) END;

  RETURN QUERY SELECT p_id, w.duration_sec, w.distance_km, w.kcal, w.kcal_source, w.hr_avg, w.hr_peak,
    (w.duration_sec / 60) || ' min'
    || coalesce(' · ' || w.distance_km || ' km', '')
    || coalesce(' · ' || v_kmh || ' km/h', '')
    || ' · ' || w.kcal || ' kcal'
    || coalesce(' · avg ' || w.hr_avg || ' bpm', '');
END $function$;

CREATE OR REPLACE FUNCTION public.workout_live(p_id uuid)
 RETURNS TABLE(elapsed_sec integer, hr_now integer, hr_avg integer, hr_peak integer, kcal integer, zone text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s record; v_rest int; v_max int; v_pct numeric;
BEGIN
  SELECT * INTO s FROM workout_sessions WHERE workout_sessions.id = p_id;
  IF s.id IS NULL THEN RETURN; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RETURN; END IF;

  elapsed_sec := GREATEST(0, extract(epoch FROM (coalesce(s.ended_at, now()) - s.started_at))::int);

  SELECT round(avg(r.heart_rate))::int, max(r.heart_rate)::int,
         (array_agg(r.heart_rate ORDER BY r.recorded_at DESC))[1]::int
    INTO hr_avg, hr_peak, hr_now
    FROM realtime_health r
   WHERE r.user_id = s.user_id AND r.heart_rate > 30
     AND r.recorded_at >= s.started_at
     AND r.recorded_at <= coalesce(s.ended_at, now());

  -- v223: heart-rate calories (Keytel), not the daily load coefficient
  kcal := coalesce((workout_energy(s.user_id, s.started_at, coalesce(s.ended_at, now()))).kcal, 0);

  SELECT coalesce(b.median, 50)::int INTO v_rest FROM personal_baselines b
   WHERE b.user_id = s.user_id AND b.metric = 'resting_hr' AND b.window_days = 30 AND b.n_obs >= 3;
  SELECT 220 - coalesce(u.age, 30) INTO v_max FROM user_body_profile u WHERE u.user_id = s.user_id;

  -- Karvonen reserve, so the zones mean the same thing at any fitness level.
  v_pct := CASE WHEN hr_now IS NULL OR v_max IS NULL OR v_max <= v_rest THEN NULL
                ELSE (hr_now - v_rest)::numeric / (v_max - v_rest) END;
  zone := CASE
    WHEN v_pct IS NULL   THEN 'no signal'
    WHEN v_pct < 0.35    THEN 'warm-up'
    WHEN v_pct < 0.55    THEN 'zone 2 — base'
    WHEN v_pct < 0.70    THEN 'zone 3 — tempo'
    WHEN v_pct < 0.85    THEN 'zone 4 — threshold'
    ELSE                      'zone 5 — max'
  END;

  RETURN NEXT;
END $function$;

CREATE OR REPLACE FUNCTION public.workout_set_environment(p_id uuid, p_environment text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE s record;
BEGIN
  IF p_environment NOT IN ('indoor', 'outdoor') THEN RAISE EXCEPTION 'environment must be indoor or outdoor'; END IF;
  SELECT * INTO s FROM workout_sessions WHERE id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RAISE EXCEPTION 'not your session'; END IF;
  UPDATE workout_sessions SET environment = p_environment WHERE id = p_id;
  IF p_environment = 'indoor' THEN
    DELETE FROM workout_routes WHERE workout_id = p_id;              -- indoors a route is GPS drift
    UPDATE workout_sessions SET elevation_gain_m = NULL,
           distance_km = CASE WHEN distance_source = 'gps' THEN pedometer_km ELSE distance_km END,
           distance_source = CASE WHEN distance_source = 'gps' THEN CASE WHEN pedometer_km IS NOT NULL THEN 'pedometer' END ELSE distance_source END
     WHERE id = p_id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.workout_attach_track(p_id uuid, p_points jsonb DEFAULT '[]'::jsonb, p_steps int DEFAULT NULL, p_pedometer_km numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  s record; pt jsonb; prev jsonb; kept jsonb := '[]'::jsonb; d numeric; dt numeric; dist numeric := 0;
  vmax numeric; gain numeric := 0; anchor numeric; alt numeric; minlat numeric; maxlat numeric; minlon numeric; maxlon numeric;
  n int := 0;
BEGIN
  SELECT * INTO s FROM workout_sessions WHERE id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RAISE EXCEPTION 'not your session'; END IF;

  -- fastest believable speed for the type, m/s
  vmax := CASE WHEN s.type_key IN ('bike_outdoor', 'cardio_bike') THEN 25 ELSE 12 END;

  IF coalesce(s.environment, 'outdoor') = 'outdoor' AND jsonb_typeof(p_points) = 'array' AND jsonb_array_length(p_points) >= 2 THEN
    FOR pt IN SELECT value FROM jsonb_array_elements(p_points) ORDER BY (value->>0)::numeric LOOP
      CONTINUE WHEN jsonb_array_length(pt) < 3;
      CONTINUE WHEN abs((pt->>1)::numeric) > 90 OR abs((pt->>2)::numeric) > 180;
      CONTINUE WHEN (pt->>4) IS NOT NULL AND (pt->>4)::numeric > 25;           -- accuracy worse than 25 m
      IF prev IS NOT NULL THEN
        dt := (pt->>0)::numeric - (prev->>0)::numeric;
        CONTINUE WHEN dt <= 0;
        d := geo_m((prev->>1)::numeric, (prev->>2)::numeric, (pt->>1)::numeric, (pt->>2)::numeric);
        CONTINUE WHEN d / dt > vmax;                                           -- a jump, not a stride
        dist := dist + d;
      END IF;
      minlat := LEAST(coalesce(minlat, (pt->>1)::numeric), (pt->>1)::numeric); maxlat := GREATEST(coalesce(maxlat, (pt->>1)::numeric), (pt->>1)::numeric);
      minlon := LEAST(coalesce(minlon, (pt->>2)::numeric), (pt->>2)::numeric); maxlon := GREATEST(coalesce(maxlon, (pt->>2)::numeric), (pt->>2)::numeric);
      kept := kept || jsonb_build_array(pt);
      prev := pt; n := n + 1;
    END LOOP;

    -- climb: GPS altitude is noisy (+/-10 m), so smooth over 5 points, then count rises past 4 m hysteresis
    FOR alt IN SELECT avg(NULLIF(e.value->>3, '')::numeric) OVER (ORDER BY e.ord ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING)
                 FROM jsonb_array_elements(kept) WITH ORDINALITY e(value, ord) ORDER BY e.ord LOOP
      CONTINUE WHEN alt IS NULL;
      IF anchor IS NULL THEN anchor := alt;
      ELSIF alt > anchor + 4 THEN gain := gain + (alt - anchor); anchor := alt;
      ELSIF alt < anchor - 4 THEN anchor := alt; END IF;
    END LOOP;

    -- never left a 40 m box: he did not go anywhere, whatever the sum of jitter says
    IF n >= 2 AND geo_m(minlat, minlon, maxlat, maxlon) < 40 THEN dist := 0; gain := 0; END IF;

    IF n >= 2 THEN
      INSERT INTO workout_routes (workout_id, user_id, points, point_count, distance_m, elevation_gain_m)
      VALUES (p_id, s.user_id, kept, n, round(dist), round(gain))
      ON CONFLICT (workout_id) DO UPDATE SET points = EXCLUDED.points, point_count = EXCLUDED.point_count,
        distance_m = EXCLUDED.distance_m, elevation_gain_m = EXCLUDED.elevation_gain_m, created_at = now();
    END IF;
  END IF;

  UPDATE workout_sessions w SET
    steps = coalesce(p_steps, w.steps),
    pedometer_km = coalesce(round(p_pedometer_km, 2), w.pedometer_km),
    elevation_gain_m = CASE WHEN dist >= 50 THEN round(gain) ELSE w.elevation_gain_m END,
    distance_km = CASE WHEN dist >= 50 THEN round(dist / 1000.0, 2)
                       WHEN w.distance_source IN ('gps', 'manual') THEN w.distance_km
                       WHEN p_pedometer_km > 0 THEN round(p_pedometer_km, 2)
                       ELSE w.distance_km END,
    distance_source = CASE WHEN dist >= 50 THEN 'gps'
                           WHEN w.distance_source IN ('gps', 'manual') THEN w.distance_source
                           WHEN p_pedometer_km > 0 THEN 'pedometer'
                           ELSE w.distance_source END
  WHERE w.id = p_id;

  SELECT * INTO s FROM workout_sessions WHERE id = p_id;
  UPDATE activities a SET metadata = coalesce(a.metadata, '{}'::jsonb) || jsonb_build_object('distance_km', s.distance_km, 'steps', s.steps)
   WHERE a.id = s.activity_id;
  RETURN jsonb_build_object('distance_km', s.distance_km, 'distance_source', s.distance_source,
                            'elevation_gain_m', s.elevation_gain_m, 'steps', s.steps, 'route_points', n);
END $$;

CREATE OR REPLACE FUNCTION public.workout_delete_route(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE s record;
BEGIN
  SELECT * INTO s FROM workout_sessions WHERE id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RAISE EXCEPTION 'not your session'; END IF;
  DELETE FROM workout_routes WHERE workout_id = p_id;
  UPDATE workout_sessions SET elevation_gain_m = NULL,
         distance_km = CASE WHEN distance_source = 'gps' THEN pedometer_km ELSE distance_km END,
         distance_source = CASE WHEN distance_source = 'gps' THEN CASE WHEN pedometer_km IS NOT NULL THEN 'pedometer' END ELSE distance_source END
   WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION public.workout_detail(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE s record; t record; ref record; a timestamptz; b timestamptz; zones jsonb; series jsonb; route jsonb := '[]'::jsonb;
        rt record; k int; v_dd int;
BEGIN
  SELECT * INTO s FROM workout_sessions WHERE id = p_id;
  IF s.id IS NULL THEN RETURN NULL; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RAISE EXCEPTION 'not your session'; END IF;
  SELECT * INTO t FROM workout_types WHERE key = s.type_key;
  SELECT * INTO ref FROM workout_hr_ref(s.user_id);

  a := LEAST(s.started_at, coalesce(s.detected_start, s.started_at), coalesce(s.logged_started_at, s.started_at)) - interval '15 min';
  b := GREATEST(coalesce(s.ended_at, now()), coalesce(s.detected_end, s.ended_at, now()), coalesce(s.logged_ended_at, s.ended_at, now())) + interval '15 min';

  SELECT coalesce(jsonb_agg(jsonb_build_array(extract(epoch FROM m)::bigint, round(hr)) ORDER BY m), '[]'::jsonb)
    INTO series FROM workout_minute_hr(s.user_id, a, b);

  -- minutes per Karvonen zone inside the workout window (same cut points as workout_live)
  WITH z AS (
    SELECT CASE WHEN p < 0.35 THEN 1 WHEN p < 0.55 THEN 2 WHEN p < 0.70 THEN 3 WHEN p < 0.85 THEN 4 ELSE 5 END zn
      FROM (SELECT (hr - ref.rest_hr) / NULLIF(ref.max_hr - ref.rest_hr, 0) p
              FROM workout_minute_hr(s.user_id, s.started_at, coalesce(s.ended_at, now()))) q)
  SELECT jsonb_build_array(count(*) FILTER (WHERE zn = 1), count(*) FILTER (WHERE zn = 2), count(*) FILTER (WHERE zn = 3),
                           count(*) FILTER (WHERE zn = 4), count(*) FILTER (WHERE zn = 5))
    INTO zones FROM z;

  SELECT * INTO rt FROM workout_routes WHERE workout_id = p_id;
  IF rt.workout_id IS NOT NULL THEN
    k := GREATEST(1, ceil(rt.point_count / 400.0)::int);                       -- at most ~400 points to draw
    SELECT coalesce(jsonb_agg(jsonb_build_array(round((e.value->>1)::numeric, 6), round((e.value->>2)::numeric, 6)) ORDER BY e.ord), '[]'::jsonb)
      INTO route FROM jsonb_array_elements(rt.points) WITH ORDINALITY e(value, ord)
     WHERE (e.ord - 1) % k = 0 OR e.ord = rt.point_count;
  END IF;

  v_dd := CASE WHEN s.detected_start IS NOT NULL AND s.detected_end IS NOT NULL
               THEN extract(epoch FROM (s.detected_end - s.detected_start))::int END;

  RETURN jsonb_build_object(
    'id', s.id, 'type_key', s.type_key, 'label', t.label, 'emoji', t.emoji,
    'environment', coalesce(s.environment, t.default_environment),
    'started_at', s.started_at, 'ended_at', s.ended_at,
    'logged_started_at', coalesce(s.logged_started_at, s.started_at), 'logged_ended_at', coalesce(s.logged_ended_at, s.ended_at),
    'detected_start', s.detected_start, 'detected_end', s.detected_end,
    'times_moved', s.logged_started_at IS NOT NULL,
    'duration_sec', s.duration_sec, 'detected_duration_sec', v_dd,
    'distance_km', s.distance_km, 'distance_source', s.distance_source, 'pedometer_km', s.pedometer_km,
    'pace_min_per_km', CASE WHEN s.distance_km > 0 AND s.duration_sec >= 60 THEN round((s.duration_sec / 60.0) / s.distance_km, 2) END,
    'kmh', CASE WHEN s.distance_km > 0 AND s.duration_sec >= 60 THEN round(s.distance_km / (s.duration_sec / 3600.0), 1) END,
    'steps', s.steps, 'elevation_gain_m', s.elevation_gain_m,
    'hr_avg', s.hr_avg, 'hr_peak', s.hr_peak, 'zones_min', zones, 'hr_series', series,
    'kcal', s.kcal, 'kcal_active', s.kcal_active, 'kcal_method', s.kcal_method, 'kcal_v174', s.kcal_v174,
    'rpe', s.rpe, 'notes', s.notes,
    'has_route', rt.workout_id IS NOT NULL, 'route', route);
END $$;

CREATE OR REPLACE FUNCTION public.workout_apply_detected(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE s record;
BEGIN
  SELECT * INTO s FROM workout_sessions WHERE id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RAISE EXCEPTION 'not your session'; END IF;
  IF s.detected_start IS NULL OR s.detected_end IS NULL THEN RETURN workout_detail(p_id); END IF;
  UPDATE workout_sessions SET
    logged_started_at = coalesce(logged_started_at, started_at),
    logged_ended_at   = coalesce(logged_ended_at, ended_at),
    started_at = detected_start, ended_at = detected_end
  WHERE id = p_id;
  PERFORM workout_recompute(p_id);
  RETURN workout_detail(p_id);
END $$;

CREATE OR REPLACE FUNCTION public.workout_revert_logged(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE s record;
BEGIN
  SELECT * INTO s FROM workout_sessions WHERE id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN RAISE EXCEPTION 'not your session'; END IF;
  IF s.logged_started_at IS NULL THEN RETURN workout_detail(p_id); END IF;
  UPDATE workout_sessions SET started_at = logged_started_at, ended_at = logged_ended_at,
         logged_started_at = NULL, logged_ended_at = NULL
   WHERE id = p_id;
  PERFORM workout_recompute(p_id);
  RETURN workout_detail(p_id);
END $$;

DROP FUNCTION IF EXISTS public.workout_recent(uuid, integer);
CREATE FUNCTION public.workout_recent(p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 30)
 RETURNS TABLE(id uuid, type_key text, label text, emoji text, started_at timestamp with time zone, duration_sec integer,
               distance_km numeric, load_level integer, rpe integer, hr_avg integer, hr_peak integer, kcal integer,
               kcal_source text, kmh numeric,
               environment text, distance_source text, steps integer, kcal_active integer, kcal_method text,
               detected_start timestamptz, detected_end timestamptz, has_route boolean)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT s.id, s.type_key, t.label, t.emoji, s.started_at, s.duration_sec,
         s.distance_km, s.load_level, s.rpe, s.hr_avg, s.hr_peak,
         s.kcal, s.kcal_source,
         CASE WHEN s.distance_km > 0 AND s.duration_sec >= 60
              THEN round(s.distance_km / (s.duration_sec / 3600.0), 1) END,
         coalesce(s.environment, t.default_environment), s.distance_source, s.steps, s.kcal_active, s.kcal_method,
         s.detected_start, s.detected_end,
         EXISTS (SELECT 1 FROM workout_routes r WHERE r.workout_id = s.id)
    FROM workout_sessions s JOIN workout_types t ON t.key = s.type_key
   WHERE s.user_id = coalesce(p_user_id, auth.uid())
     AND s.ended_at IS NOT NULL
   ORDER BY s.started_at DESC
   LIMIT p_limit;
$function$;

-- internal helpers are not for the API
REVOKE EXECUTE ON FUNCTION public.workout_hr_ref(uuid), public.workout_minute_hr(uuid, timestamptz, timestamptz),
  public.workout_detect_bounds(uuid, timestamptz, timestamptz), public.workout_energy(uuid, timestamptz, timestamptz),
  public.workout_recompute(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.workout_set_environment(uuid, text), public.workout_attach_track(uuid, jsonb, int, numeric),
  public.workout_delete_route(uuid), public.workout_detail(uuid), public.workout_apply_detected(uuid),
  public.workout_revert_logged(uuid), public.workout_recent(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.workout_set_environment(uuid, text), public.workout_attach_track(uuid, jsonb, int, numeric),
  public.workout_delete_route(uuid), public.workout_detail(uuid), public.workout_apply_detected(uuid),
  public.workout_revert_logged(uuid), public.workout_recent(uuid, integer) TO authenticated, service_role;

-- ── re-score every finished workout; keep the old figure in kcal_v174 ──────
UPDATE public.workout_sessions SET kcal_v174 = kcal WHERE kcal_v174 IS NULL AND ended_at IS NOT NULL;
UPDATE public.workout_sessions w SET environment = t.default_environment
  FROM public.workout_types t WHERE t.key = w.type_key AND w.environment IS NULL;
UPDATE public.workout_sessions SET distance_source = 'manual' WHERE distance_km IS NOT NULL AND distance_source IS NULL;
SELECT public.workout_recompute(id) FROM public.workout_sessions WHERE ended_at IS NOT NULL;

COMMIT;
