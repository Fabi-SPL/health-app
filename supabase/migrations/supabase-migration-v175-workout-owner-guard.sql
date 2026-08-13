-- v175 — Make the by-id workout RPCs check who is asking.
--
-- v174 shipped workout_live / workout_finish / workout_cancel taking a bare
-- session uuid. They are SECURITY DEFINER, so they run past the RLS policy on
-- workout_sessions: any authenticated caller who guessed an id could read
-- someone else's heart rate, close their session, or delete it. There is
-- exactly one user on this server today, which is why nothing broke — but a
-- SECURITY DEFINER function that never asks whose row it is holding is a hole
-- regardless of how many people are standing in front of it.
--
-- The guard is deliberately null-tolerant: auth.uid() is NULL when the call
-- arrives with the service key, which is already all-powerful and is how the
-- migrations and probes talk to this database. What has to be stopped is a
-- *user* JWT reaching another user's row, and that is exactly the case where
-- auth.uid() is populated.
--
-- Each function is restated whole rather than wrapped. A wrapper would leave
-- the real body reachable under a second name, and renaming on every apply is
-- not idempotent.

-- ── live ─────────────────────────────────────────────────────────────────────
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

GRANT EXECUTE ON FUNCTION public.workout_finish(uuid, numeric, int, int, text) TO authenticated;


-- ── cancel ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.workout_cancel(p_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  DELETE FROM workout_sessions
   WHERE id = p_id
     AND ended_at IS NULL
     AND (auth.uid() IS NULL OR user_id = auth.uid());
$function$;

GRANT EXECUTE ON FUNCTION public.workout_cancel(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
