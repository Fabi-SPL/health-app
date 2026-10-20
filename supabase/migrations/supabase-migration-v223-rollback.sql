-- v223 rollback: back to the v174 workout functions and the old load x 1.5 calories.
-- Routes are deleted with the table. Restores kcal from kcal_v174 and the logged start/end where they were moved.
BEGIN;
UPDATE public.workout_sessions SET started_at = logged_started_at, ended_at = logged_ended_at
 WHERE logged_started_at IS NOT NULL;
UPDATE public.workout_sessions SET kcal = kcal_v174 WHERE kcal_v174 IS NOT NULL;
UPDATE public.workout_sessions SET duration_sec = GREATEST(1, extract(epoch FROM (ended_at - started_at))::int) WHERE ended_at IS NOT NULL;

DROP FUNCTION IF EXISTS public.workout_set_environment(uuid, text);
DROP FUNCTION IF EXISTS public.workout_attach_track(uuid, jsonb, int, numeric);
DROP FUNCTION IF EXISTS public.workout_delete_route(uuid);
DROP FUNCTION IF EXISTS public.workout_apply_detected(uuid);
DROP FUNCTION IF EXISTS public.workout_revert_logged(uuid);
DROP FUNCTION IF EXISTS public.workout_detail(uuid);
DROP FUNCTION IF EXISTS public.workout_recent(uuid, integer);

CREATE FUNCTION public.workout_recent(p_user_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 30)
 RETURNS TABLE(id uuid, type_key text, label text, emoji text, started_at timestamp with time zone, duration_sec integer, distance_km numeric, load_level integer, rpe integer, hr_avg integer, hr_peak integer, kcal integer, kcal_source text, kmh numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

GRANT EXECUTE ON FUNCTION public.workout_recent(uuid, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.workout_start(p_type text, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, type_key text, label text, emoji text, started_at timestamp with time zone, tracks_distance boolean, tracks_load boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

CREATE OR REPLACE FUNCTION public.workout_finish(p_id uuid, p_distance_km numeric DEFAULT NULL::numeric, p_load integer DEFAULT NULL::integer, p_rpe integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, duration_sec integer, distance_km numeric, kcal integer, kcal_source text, hr_avg integer, hr_peak integer, headline text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s record; t record; v_end timestamptz := now();
  v_dur int; v_load numeric; v_kcal int; v_src text;
  v_hr_avg int; v_hr_peak int; v_weight numeric; v_act uuid; v_kmh numeric;
BEGIN
  SELECT * INTO s FROM workout_sessions w WHERE w.id = p_id;
  IF s.id IS NULL THEN RAISE EXCEPTION 'no such session'; END IF;
  IF auth.uid() IS NOT NULL AND s.user_id <> auth.uid() THEN
    RAISE EXCEPTION 'not your session';
  END IF;
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

CREATE OR REPLACE FUNCTION public.workout_live(p_id uuid)
 RETURNS TABLE(elapsed_sec integer, hr_now integer, hr_avg integer, hr_peak integer, kcal integer, zone text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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

DROP FUNCTION IF EXISTS public.workout_recompute(uuid);
DROP FUNCTION IF EXISTS public.workout_energy(uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.workout_detect_bounds(uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.workout_minute_hr(uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS public.workout_hr_ref(uuid);
DROP FUNCTION IF EXISTS public.workout_keytel(numeric, numeric, numeric, numeric, boolean);
DROP FUNCTION IF EXISTS public.geo_m(numeric, numeric, numeric, numeric);
DROP TABLE IF EXISTS public.workout_routes;
ALTER TABLE public.workout_sessions DROP CONSTRAINT IF EXISTS workout_sessions_environment_chk;
ALTER TABLE public.workout_sessions
  DROP COLUMN IF EXISTS environment, DROP COLUMN IF EXISTS distance_source, DROP COLUMN IF EXISTS pedometer_km,
  DROP COLUMN IF EXISTS steps, DROP COLUMN IF EXISTS elevation_gain_m, DROP COLUMN IF EXISTS detected_start,
  DROP COLUMN IF EXISTS detected_end, DROP COLUMN IF EXISTS logged_started_at, DROP COLUMN IF EXISTS logged_ended_at,
  DROP COLUMN IF EXISTS kcal_active, DROP COLUMN IF EXISTS kcal_method, DROP COLUMN IF EXISTS kcal_v174;
ALTER TABLE public.workout_types DROP COLUMN IF EXISTS default_environment;
COMMIT;
