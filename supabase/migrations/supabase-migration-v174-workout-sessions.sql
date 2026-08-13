-- v174 — Workouts you start, watch, and finish.
--
-- He wants the cardio bike tracked properly: how long, how far, what resistance,
-- and then to see how that lands against VO2max, clarity and next-day recovery.
-- `activities` already exists but it is a flat after-the-fact record — no live
-- session, no distance, no resistance dial.
--
-- Three decisions worth stating:
--
--   1. The type catalog is a TABLE, not a Swift enum. Adding "rowing" later is
--      an INSERT, not an App Store build. Same reasoning as everything else
--      here: the client displays, the server decides.
--
--   2. Calories come from HR load over the exact session window (body_load_bpmh
--      x 1.5, the same calibration active_kcal uses) so a ride never double
--      counts against the daily figure — it IS the daily figure, windowed.
--      When the strap was off, fall back to a MET estimate built from the
--      resistance dial. That is what makes logging the load worth doing.
--
--   3. One open session per user, enforced by a partial unique index. Starting
--      a second one returns the first rather than erroring — a double tap on
--      "Start" should not be a failure state.

CREATE TABLE IF NOT EXISTS public.workout_types (
  key             text PRIMARY KEY,
  label           text NOT NULL,
  emoji           text NOT NULL DEFAULT '💪',
  category        text NOT NULL DEFAULT 'cardio',
  tracks_distance boolean NOT NULL DEFAULT true,
  tracks_load     boolean NOT NULL DEFAULT false,
  -- MET at resistance 0 and the MET added per point on the 1-10 dial. Only used
  -- when there is no heart-rate data to work from.
  met_base        numeric NOT NULL DEFAULT 6.0,
  met_per_load    numeric NOT NULL DEFAULT 0.0,
  sort_order      int NOT NULL DEFAULT 100,
  active          boolean NOT NULL DEFAULT true
);

INSERT INTO public.workout_types (key, label, emoji, category, tracks_distance, tracks_load, met_base, met_per_load, sort_order) VALUES
  ('cardio_bike',   'Cardio Bike',   '🚴', 'cardio',   true,  true,  4.0, 0.8, 10),
  ('bike_outdoor',  'Bike (outside)','🚲', 'cardio',   true,  false, 7.5, 0.0, 20),
  ('walk',          'Walk',          '🚶', 'cardio',   true,  false, 3.5, 0.0, 30),
  ('run',           'Run',           '🏃', 'cardio',   true,  false, 9.8, 0.0, 40),
  ('strength',      'Gym',           '🏋️', 'strength', false, false, 5.0, 0.0, 50),
  ('rowing',        'Rowing',        '🚣', 'cardio',   true,  true,  5.0, 0.7, 60)
ON CONFLICT (key) DO NOTHING;

GRANT SELECT ON public.workout_types TO authenticated;


CREATE TABLE IF NOT EXISTS public.workout_sessions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL,
  type_key     text NOT NULL REFERENCES public.workout_types(key),
  started_at   timestamptz NOT NULL DEFAULT now(),
  ended_at     timestamptz,
  duration_sec int,
  distance_km  numeric,
  load_level   int CHECK (load_level BETWEEN 1 AND 10),
  rpe          int CHECK (rpe BETWEEN 1 AND 10),
  hr_avg       int,
  hr_peak      int,
  load_bpmh    numeric,
  kcal         int,
  kcal_source  text,               -- 'hr' when the strap was on, 'estimate' otherwise
  notes        text,
  activity_id  uuid REFERENCES public.activities(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS workout_sessions_user_time
  ON public.workout_sessions (user_id, started_at DESC);

-- A second "Start" while one is running is a fat finger, not a second workout.
CREATE UNIQUE INDEX IF NOT EXISTS workout_sessions_one_open
  ON public.workout_sessions (user_id) WHERE ended_at IS NULL;

ALTER TABLE public.workout_sessions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS workout_sessions_own ON public.workout_sessions;
CREATE POLICY workout_sessions_own ON public.workout_sessions
  FOR ALL USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());


-- ── start ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.workout_start(
  p_type text,
  p_user_id uuid DEFAULT NULL
)
RETURNS TABLE (id uuid, type_key text, label text, emoji text,
               started_at timestamptz, tracks_distance boolean, tracks_load boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
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
    INSERT INTO workout_sessions (user_id, type_key) VALUES (v_user, p_type)
    RETURNING workout_sessions.id INTO v_id;
  END IF;

  RETURN QUERY
    SELECT s.id, s.type_key, t.label, t.emoji, s.started_at, t.tracks_distance, t.tracks_load
      FROM workout_sessions s JOIN workout_types t ON t.key = s.type_key
     WHERE s.id = v_id;
END $function$;

GRANT EXECUTE ON FUNCTION public.workout_start(text, uuid) TO authenticated;


-- ── live tick ────────────────────────────────────────────────────────────────
-- Polled by the live screen. Everything it shows is computed here so the app
-- never has to know the calibration.
CREATE OR REPLACE FUNCTION public.workout_live(p_id uuid)
RETURNS TABLE (elapsed_sec int, hr_now int, hr_avg int, hr_peak int,
               kcal int, zone text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  s record; v_rest int; v_max int; v_pct numeric;
BEGIN
  SELECT * INTO s FROM workout_sessions WHERE workout_sessions.id = p_id;
  IF s.id IS NULL THEN RETURN; END IF;

  elapsed_sec := GREATEST(0, extract(epoch FROM (coalesce(s.ended_at, now()) - s.started_at))::int);

  SELECT round(avg(r.heart_rate))::int, max(r.heart_rate)::int,
         (array_agg(r.heart_rate ORDER BY r.recorded_at DESC))[1]::int
    INTO hr_avg, hr_peak, hr_now
    FROM realtime_health r
   WHERE r.user_id = s.user_id AND r.heart_rate > 30
     AND r.recorded_at >= s.started_at
     AND r.recorded_at <= coalesce(s.ended_at, now());

  kcal := round(body_load_bpmh(s.user_id, s.started_at, coalesce(s.ended_at, now())) * 1.5)::int;

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

GRANT EXECUTE ON FUNCTION public.workout_live(uuid) TO authenticated;


-- ── finish ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.workout_finish(
  p_id uuid,
  p_distance_km numeric DEFAULT NULL,
  p_load int DEFAULT NULL,
  p_rpe int DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS TABLE (id uuid, duration_sec int, distance_km numeric,
               kcal int, kcal_source text, hr_avg int, hr_peak int, headline text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  s record; t record; v_end timestamptz := now();
  v_dur int; v_load numeric; v_kcal int; v_src text;
  v_hr_avg int; v_hr_peak int; v_weight numeric; v_act uuid; v_kmh numeric;
BEGIN
  SELECT * INTO s FROM workout_sessions w WHERE w.id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF s.ended_at IS NOT NULL THEN v_end := s.ended_at; END IF;

  SELECT * INTO t FROM workout_types WHERE key = s.type_key;
  v_dur := GREATEST(1, extract(epoch FROM (v_end - s.started_at))::int);

  SELECT round(avg(r.heart_rate))::int, max(r.heart_rate)::int
    INTO v_hr_avg, v_hr_peak
    FROM realtime_health r
   WHERE r.user_id = s.user_id AND r.heart_rate > 30
     AND r.recorded_at >= s.started_at AND r.recorded_at <= v_end;

  v_load := body_load_bpmh(s.user_id, s.started_at, v_end);

  v_kcal := round(v_load * 1.5)::int;

  -- Test the OUTPUT, not the input. A strap that was on but flat-lined at
  -- resting produces a positive-but-negligible load, which would otherwise be
  -- stamped 'hr' and reported as a 0 kcal ride.
  IF v_kcal >= 1 THEN
    v_src := 'hr';
  ELSE
    -- No usable signal. Rebuild it from the resistance dial and bodyweight.
    SELECT weight_kg INTO v_weight FROM user_body_profile WHERE user_id = s.user_id;
    v_kcal := round((t.met_base + t.met_per_load * coalesce(p_load, 5))
                    * coalesce(v_weight, 75) * (v_dur / 3600.0))::int;
    v_src  := 'estimate';
  END IF;

  UPDATE workout_sessions w SET
    ended_at = v_end, duration_sec = v_dur,
    distance_km = coalesce(p_distance_km, w.distance_km),
    load_level = coalesce(p_load, w.load_level),
    rpe = coalesce(p_rpe, w.rpe),
    hr_avg = v_hr_avg, hr_peak = v_hr_peak,
    load_bpmh = v_load, kcal = v_kcal, kcal_source = v_src,
    notes = coalesce(p_notes, w.notes)
  WHERE w.id = p_id;

  -- Mirror into `activities` so the correlation engine sees it alongside sleep,
  -- food and mood without needing to learn a second table.
  INSERT INTO activities (user_id, activity_type, display_name, emoji,
                          started_at, ended_at, source, hr_avg, hr_peak,
                          canonical_activity_type, canonical_category, canonical_emoji, metadata)
  -- activities.source is constrained to auto|tap|dump|manual. 'tap' is already
  -- overloaded by the Whoop double-tap quick-tag, so a deliberate start/stop
  -- lands as 'manual' and is told apart by metadata.workout_session_id.
  VALUES (s.user_id, s.type_key, t.label, t.emoji, s.started_at, v_end, 'manual',
          v_hr_avg, v_hr_peak, s.type_key, t.category, t.emoji,
          jsonb_build_object('workout_session_id', p_id, 'distance_km', p_distance_km,
                             'load_level', p_load, 'rpe', p_rpe, 'kcal', v_kcal))
  RETURNING activities.id INTO v_act;

  UPDATE workout_sessions w SET activity_id = v_act WHERE w.id = p_id;

  -- Under a minute the pace figure is meaningless (10 km in 36 s reads 1000 km/h).
  v_kmh := CASE WHEN p_distance_km > 0 AND v_dur >= 60
                THEN round(p_distance_km / (v_dur / 3600.0), 1) END;

  RETURN QUERY SELECT p_id, v_dur, p_distance_km, v_kcal, v_src, v_hr_avg, v_hr_peak,
    (v_dur / 60) || ' min'
    || coalesce(' · ' || p_distance_km || ' km', '')
    || coalesce(' · ' || v_kmh || ' km/h', '')
    || ' · ' || v_kcal || ' kcal'
    || coalesce(' · avg ' || v_hr_avg || ' bpm', '');
END $function$;

GRANT EXECUTE ON FUNCTION public.workout_finish(uuid, numeric, int, int, text) TO authenticated;


-- ── read side ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.workout_recent(
  p_user_id uuid DEFAULT NULL,
  p_limit int DEFAULT 30
)
RETURNS TABLE (id uuid, type_key text, label text, emoji text,
               started_at timestamptz, duration_sec int, distance_km numeric,
               load_level int, rpe int, hr_avg int, hr_peak int,
               kcal int, kcal_source text, kmh numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT s.id, s.type_key, t.label, t.emoji, s.started_at, s.duration_sec,
         s.distance_km, s.load_level, s.rpe, s.hr_avg, s.hr_peak,
         s.kcal, s.kcal_source,
         CASE WHEN s.distance_km > 0 AND s.duration_sec >= 60
              THEN round(s.distance_km / (s.duration_sec / 3600.0), 1) END
    FROM workout_sessions s JOIN workout_types t ON t.key = s.type_key
   WHERE s.user_id = coalesce(p_user_id, auth.uid())
     AND s.ended_at IS NOT NULL
   ORDER BY s.started_at DESC
   LIMIT p_limit;
$function$;

GRANT EXECUTE ON FUNCTION public.workout_recent(uuid, int) TO authenticated;


-- Open session, so the app can rejoin a ride after being backgrounded or killed.
CREATE OR REPLACE FUNCTION public.workout_open(p_user_id uuid DEFAULT NULL)
RETURNS TABLE (id uuid, type_key text, label text, emoji text,
               started_at timestamptz, tracks_distance boolean, tracks_load boolean)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT s.id, s.type_key, t.label, t.emoji, s.started_at, t.tracks_distance, t.tracks_load
    FROM workout_sessions s JOIN workout_types t ON t.key = s.type_key
   WHERE s.user_id = coalesce(p_user_id, auth.uid()) AND s.ended_at IS NULL
   ORDER BY s.started_at DESC LIMIT 1;
$function$;

GRANT EXECUTE ON FUNCTION public.workout_open(uuid) TO authenticated;


-- Abandon: started it, never rode. Deletes rather than storing a 4-second ride.
CREATE OR REPLACE FUNCTION public.workout_cancel(p_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  DELETE FROM workout_sessions WHERE id = p_id AND ended_at IS NULL;
$function$;

GRANT EXECUTE ON FUNCTION public.workout_cancel(uuid) TO authenticated;
