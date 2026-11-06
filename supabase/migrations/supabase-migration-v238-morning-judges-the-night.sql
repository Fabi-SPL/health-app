-- v238: the morning judges the night, so the tap is optional in both directions.
-- Mean heart rate over the first half of sleep separated drinking nights far better than resting HR
-- (AUC 0.993 vs 0.944, 9 drinking / 17 sober nights, in-sample). Alcohol is mostly gone by mid-night, so the
-- minimum dilutes what the first half still carries. It is also the one signal VR cannot fake: 2 h of gaming
-- before bed left sleep HR unchanged (Alesi 2026).
-- An evening the meter opened now stands or falls on the next morning: no first-half excess, and the night goes
-- back to sober and is re-scored. A slow night the evening meter missed gets caught the same way. A rise that is
-- still there two nights later reads uncertain, not drinking (illness raises HR over days, Mishra 2020).
-- The VR bar goes back to 60: it only ever added 10-24, which the morning now catches, and VR lifts HR by itself
-- (Zekioglu 2026) with no sober VR evening of his measured yet.
-- Breath fit: 20 min wait (Modell 1993), falling limb only (Jones & Cowan 2020), two nights before it applies.
-- Baseline skips evenings after under 6.5 h sleep (Mateo 2026): meter opens 30 min earlier in replay, no new false alarm.

BEGIN;

ALTER TABLE public.drink_nights ADD COLUMN IF NOT EXISTS first_half_hr numeric(5,1);
ALTER TABLE public.drink_nights ADD COLUMN IF NOT EXISTS first_half_delta numeric(5,1);

CREATE OR REPLACE FUNCTION public.sleep_first_half_hr(p_user uuid, p_night date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT round(avg(m.hr)::numeric, 1)
    FROM public.health_metrics h
    CROSS JOIN LATERAL (
      SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY r.heart_rate) hr
        FROM public.realtime_health r
       WHERE r.user_id = h.user_id AND r.heart_rate > 30
         AND r.recorded_at >= h.sleep_start AND r.recorded_at < h.sleep_start + (h.sleep_end - h.sleep_start) / 2
       GROUP BY date_trunc('minute', r.recorded_at)) m
   WHERE h.user_id = p_user AND h.metric_date = p_night AND h.night_data = 'complete'
$function$;
REVOKE ALL ON FUNCTION public.sleep_first_half_hr(uuid, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sleep_first_half_hr(uuid, date) TO service_role;

CREATE OR REPLACE FUNCTION public.drinking_flagged_night(p_user_id uuid, p_night date)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.drinking_tapped_night(p_user_id, p_night) OR (
    EXISTS (SELECT 1 FROM drink_nights n
             WHERE n.user_id = p_user_id AND n.night = p_night
               -- v238: the morning label decides; an opened night counts until it says otherwise
               AND (n.label = 'drinking' AND n.label_source IN ('fabi', 'breath', 'overnight', 'correction')
                    OR (n.opened_at IS NOT NULL AND n.label IS DISTINCT FROM 'sober')))
    -- his word beats the detector: a 'not drinking' tap or a 'sober' correction that night closes it
    AND NOT coalesce((SELECT NOT a.manual_drinking FROM alcohol_flags a
                       WHERE a.user_id = p_user_id AND public.night_of(a.created_at) = p_night
                       ORDER BY a.created_at DESC LIMIT 1), false)
    AND coalesce((SELECT lower(t.corrected_state) FROM state_truth_log t
                   WHERE t.user_id = p_user_id AND t.detector = 'drunk' AND public.night_of(t.ts) = p_night
                     AND t.corrected_state IS NOT NULL
                   ORDER BY t.ts DESC LIMIT 1), '') <> 'sober')
$function$;

CREATE OR REPLACE FUNCTION public.drunk_confirm_nights(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, p_days integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_med numeric; v_fmed numeric; v_auto numeric; r record; v_delta numeric; v_fd numeric; v_label text; v_src text;
        v_n int := 0; v_said text; v_tap boolean; v_open boolean; v_ill boolean;
BEGIN
  v_auto := coalesce((SELECT (cfg#>>'{drunk,hr_floor,auto_open_at}')::numeric FROM public.biostate_config WHERE user_id = p_user), 60);
  -- a first-half HR for every night in the window, before the sober median that reads it
  INSERT INTO public.drink_nights AS n (user_id, night, first_half_hr)
  SELECT p_user, h.metric_date, public.sleep_first_half_hr(p_user, h.metric_date)
    FROM public.health_metrics h
   WHERE h.user_id = p_user AND h.metric_date > current_date - p_days AND h.metric_date <= current_date AND h.night_data = 'complete'
  ON CONFLICT (user_id, night) DO UPDATE SET first_half_hr = EXCLUDED.first_half_hr, updated_at = now();

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY h.resting_hr),
         percentile_cont(0.5) WITHIN GROUP (ORDER BY d.first_half_hr) INTO v_med, v_fmed
    FROM public.health_metrics h
    LEFT JOIN public.drink_nights d ON d.user_id = h.user_id AND d.night = h.metric_date
   WHERE h.user_id = p_user AND h.metric_date >= current_date - 35 AND h.night_data = 'complete' AND h.resting_hr > 0
     AND coalesce(d.label, 'sober') = 'sober';

  FOR r IN
    SELECT h.metric_date night, h.resting_hr rhr, d.label, d.label_source, d.opened_at, d.peak, d.first_half_hr fh
      FROM public.health_metrics h
      LEFT JOIN public.drink_nights d ON d.user_id = h.user_id AND d.night = h.metric_date
     WHERE h.user_id = p_user AND h.metric_date > current_date - p_days AND h.metric_date <= current_date
       AND h.night_data = 'complete' AND h.resting_hr > 0
  LOOP
    v_delta := r.rhr - v_med;
    v_fd := r.fh - v_fmed;
    v_tap := public.drinking_tapped_night(p_user, r.night);
    v_open := r.opened_at IS NOT NULL OR coalesce(r.peak, 0) >= v_auto;
    SELECT lower(t.corrected_state) INTO v_said FROM public.state_truth_log t
     WHERE t.user_id = p_user AND t.detector = 'drunk' AND public.night_of(t.ts) = r.night AND t.corrected_state IS NOT NULL
     ORDER BY t.ts DESC LIMIT 1;
    -- still raised on the next one or two nights, with no drinking evening in between: illness or surgery, not alcohol
    v_ill := EXISTS (SELECT 1 FROM public.health_metrics h2
                       LEFT JOIN public.drink_nights d2 ON d2.user_id = h2.user_id AND d2.night = h2.metric_date
                      WHERE h2.user_id = p_user AND h2.metric_date IN (r.night + 1, r.night + 2)
                        AND h2.resting_hr - v_med >= 2.5 AND coalesce(d2.peak, 0) < v_auto
                        AND NOT public.drinking_tapped_night(p_user, h2.metric_date));
    v_label := CASE
      WHEN v_tap THEN 'drinking'
      WHEN v_said = 'sober' THEN 'sober'
      WHEN v_said IS NOT NULL THEN 'drinking'
      WHEN v_fd IS NULL THEN CASE                                          -- no first half (data gap): resting HR
             WHEN v_open AND v_delta >= 2.5 THEN 'drinking'
             WHEN NOT v_open AND v_delta >= 3.5 AND coalesce(r.peak, 0) >= 30 THEN 'drinking'
             WHEN v_open OR v_delta >= 3.5 THEN 'uncertain'
             ELSE 'sober' END
      WHEN v_open AND v_fd >= 2.5 OR NOT v_open AND v_fd >= 4 AND coalesce(r.peak, 0) >= 30
        THEN CASE WHEN v_ill THEN 'uncertain' ELSE 'drinking' END
      WHEN NOT v_open AND v_fd >= 4 THEN 'uncertain'
      ELSE 'sober' END;
    v_src := CASE WHEN v_tap THEN 'tap' WHEN v_said IS NOT NULL THEN 'correction' ELSE 'overnight' END;
    INSERT INTO public.drink_nights AS n (user_id, night, label, label_source, rhr, rhr_delta, first_half_delta)
    VALUES (p_user, r.night, v_label, v_src, r.rhr, v_delta, v_fd)
    ON CONFLICT (user_id, night) DO UPDATE SET rhr = EXCLUDED.rhr, rhr_delta = EXCLUDED.rhr_delta,
      first_half_delta = EXCLUDED.first_half_delta, updated_at = now(),
      label = CASE WHEN n.label_source IN ('fabi', 'breath') THEN n.label ELSE EXCLUDED.label END,
      label_source = CASE WHEN n.label_source IN ('fabi', 'breath') THEN n.label_source ELSE EXCLUDED.label_source END;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('nights', v_n, 'sober_rhr_median', v_med, 'sober_first_half_median', v_fmed);
END $function$;

CREATE OR REPLACE FUNCTION public.drunk_daily(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_before jsonb; v_confirm jsonb; v_flipped int := 0; r record;
BEGIN
  SELECT coalesce(jsonb_object_agg(d::date::text, public.drinking_flagged_night(p_user, d::date)), '{}') INTO v_before
    FROM generate_series(current_date - 2, current_date, interval '1 day') d;
  v_confirm := public.drunk_confirm_nights(p_user, 3);
  -- a night the morning changed gets re-scored under the right rules, same as a tap would
  FOR r IN SELECT d::date night FROM generate_series(current_date - 2, current_date, interval '1 day') d
            WHERE public.drinking_flagged_night(p_user, d::date) IS DISTINCT FROM (v_before->>(d::date::text))::boolean
  LOOP
    BEGIN
      PERFORM public.recompute_health_metrics(p_user, r.night);
      v_flipped := v_flipped + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'drunk_daily: recompute % failed: %', r.night, SQLERRM;
    END;
  END LOOP;
  RETURN jsonb_build_object('confirm', v_confirm, 'rescored', v_flipped,
                            'baseline', public.refresh_drunk_baseline(p_user, 35),
                            'fit', public.fit_drunk_scale(p_user, true));
END $function$;

CREATE OR REPLACE FUNCTION public.fit_drunk_scale(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_n int; v_nights int; v_s numeric; v_mae numeric; v_beta numeric; v_k numeric; v_out jsonb;
BEGIN
  DROP TABLE IF EXISTS pg_temp._br;
  CREATE TEMP TABLE _br ON COMMIT DROP AS
    SELECT b.night, b.ts, b.promille::numeric p, (public.drunk_now(p_user, b.ts, false)->>'intensity')::numeric a
      FROM public.breath_readings b
      JOIN public.drink_nights n ON n.user_id = b.user_id AND n.night = b.night
     WHERE b.user_id = p_user AND b.ts > now() - interval '60 days' AND b.promille > 0
       AND coalesce(b.wait_min, 20) >= 20                     -- mouth alcohol
       AND n.peak_at IS NOT NULL AND b.ts >= n.peak_at;       -- v238: falling limb only
  SELECT count(*) FILTER (WHERE a > 0), count(DISTINCT night) FILTER (WHERE a > 0) INTO v_n, v_nights FROM _br;
  IF v_n < 4 THEN RETURN jsonb_build_object('fitted', false, 'reason', 'too_few_readings', 'readings', v_n); END IF;
  SELECT sum(p * a) / nullif(sum(a * a), 0) INTO v_s FROM _br WHERE a > 0;
  v_s := greatest(0.004, least(0.03, v_s));
  SELECT avg(abs(p - a * v_s)) INTO v_mae FROM _br WHERE a > 0;
  -- falling limb per night: everything after his highest reading, at least 3 readings
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY -slope) INTO v_beta FROM (
    SELECT regr_slope(b.p, extract(epoch from b.ts) / 3600) slope
      FROM _br b JOIN (SELECT DISTINCT ON (night) night, ts FROM _br ORDER BY night, p DESC, ts DESC) m
        ON m.night = b.night AND b.ts >= m.ts
     GROUP BY b.night HAVING count(*) >= 3) x WHERE slope < 0;
  v_beta := greatest(0.08, least(0.30, coalesce(v_beta, 0.15)));
  v_k := greatest(6, least(24, v_beta / v_s));
  v_out := jsonb_build_object('fitted', true, 'readings', v_n, 'nights', v_nights, 'promille_per_point', round(v_s, 5),
    'beta_per_h', round(v_beta, 3), 'elim_per_h', round(v_k, 1), 'mae_promille', round(v_mae, 3), 'fitted_at', now());
  -- one night is one set of conditions and each reading carries 8-12% error: it reports, two nights apply
  IF p_apply AND v_nights >= 2 THEN
    UPDATE public.biostate_config
       SET cfg = jsonb_set(cfg, '{drunk,hr_floor}', (cfg->'drunk'->'hr_floor')
             || jsonb_build_object('promille_per_point', round(v_s, 5), 'elim_per_h', round(v_k, 1), 'calibration', v_out))
     WHERE user_id = p_user;
  END IF;
  RETURN v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.drunk_now(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, p_end timestamp with time zone DEFAULT now(), p_persist boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c jsonb;
  e0 numeric; e1 numeric; tau numeric; k numeric; hyst numeric; lookback int; stale int;
  ev_from int; ev_to int; suspect_at numeric; act_el numeric; auto_open boolean; auto_at numeric; vr_at numeric;
  ppp numeric; v_basis text; v_vr boolean := false; v_closed boolean := false; v_src text; v_latched text;
  v_night date; v_flag boolean; v_open boolean; v_gated boolean; v_reason text;
  v_base numeric[]; v_sleep tstzrange[]; v_work tstzrange[];
  v_last timestamptz; v_age numeric; v_cov numeric; v_conf numeric;
  r record; v_slot int; v_h int; v_el numeric; v_L numeric; v_dt numeric; v_pt timestamptz;
  v_A numeric := 0; v_stage int := 0; v_raw int; v_asleep boolean := false; v_active boolean := false;
  v_slept boolean := false;
  v_peak numeric := 0; v_peak_at timestamptz; v_first20 timestamptz; v_A30 numeric;
  v_last_bkt timestamptz; v_last_med numeric; v_last_floor numeric; v_last_base numeric; v_last_el numeric;
  v_labels text[] := ARRAY['sober','buzzed','tipsy','drunk','wasted'];
  v_note text := 'Estimate from your heart rate against your own sober evenings. Not a blood alcohol test. Never use it to decide whether you can drive.';
  v_out jsonb;
BEGIN
  SELECT cfg->'drunk'->'hr_floor' INTO c FROM public.biostate_config WHERE user_id = p_user;
  c := coalesce(c, '{}'::jsonb);
  e0 := coalesce((c->>'e0')::numeric, 8);          e1 := coalesce((c->>'e1')::numeric, 30);
  tau := coalesce((c->>'tau_min')::numeric, 45);   k := coalesce((c->>'elim_per_h')::numeric, 12);
  hyst := coalesce((c->>'hysteresis')::numeric, 4);
  lookback := coalesce((c->>'lookback_h')::int, 10); stale := coalesce((c->>'stale_min')::int, 15);
  ev_from := coalesce((c->>'evidence_from_h')::int, 16); ev_to := coalesce((c->>'evidence_to_h')::int, 8);
  suspect_at := coalesce((c->>'suspect_at')::numeric, 40); act_el := coalesce((c->>'active_el')::numeric, 45);
  auto_open := coalesce((c->>'auto_open')::boolean, false); auto_at := coalesce((c->>'auto_open_at')::numeric, 60);
  vr_at := coalesce((c->>'vr_open_at')::numeric, 30);
  -- 12 points/h falling = 0.15 promille/h elimination until breath readings replace it
  ppp := coalesce((c->>'promille_per_point')::numeric, 0.0125);
  v_basis := CASE WHEN c ? 'promille_per_point' THEN 'breath' ELSE 'prior' END;

  -- the tap belongs to the night it was made for (v207), not to today's calendar date
  v_night := public.night_of(p_end);
  v_flag := public.drinking_tapped_night(p_user, v_night);
  -- his word beats the detector both ways: a 'not drinking' tap or a 'sober' correction keeps the automatic gate shut
  v_closed := NOT v_flag AND (
    coalesce((SELECT NOT a.manual_drinking FROM public.alcohol_flags a
               WHERE a.user_id = p_user AND public.night_of(a.created_at) = v_night
               ORDER BY a.created_at DESC LIMIT 1), false)
    OR EXISTS (SELECT 1 FROM public.state_truth_log t
                WHERE t.user_id = p_user AND t.detector = 'drunk' AND lower(coalesce(t.corrected_state, '')) = 'sober'
                  AND t.ts <= p_end AND t.ts > p_end - interval '3 hours'));
  SELECT n.opened_by INTO v_latched FROM public.drink_nights n
   WHERE n.user_id = p_user AND n.night = v_night AND n.opened_at <= p_end;
  SELECT coalesce(v.vr_live_until > p_end, false) INTO v_vr FROM public.vrc_settings v WHERE v.user_id = p_user;
  v_vr := coalesce(v_vr, false);

  SELECT array_agg(floor_bpm ORDER BY slot) INTO v_base
    FROM public.drunk_floor_baseline WHERE user_id = p_user;
  IF coalesce(array_length(v_base, 1), 0) < 48 THEN
    RETURN jsonb_build_object('experimental', true, 'detector', 'drunk', 'model', 'hr_floor_v236', 'ts', p_end,
      'gated', NOT v_flag, 'alcohol_mode', v_flag, 'stage', NULL, 'label', 'unknown', 'confidence', 0,
      'reason', 'no_baseline', 'note', v_note);
  END IF;

  -- asleep: last nights' scored sleep, plus tonight's live onset from the alarm session
  SELECT array_agg(tstzrange(s0, s1, '[)')) INTO v_sleep FROM (
    SELECT h.sleep_start s0, h.sleep_end s1 FROM public.health_metrics h
     WHERE h.user_id = p_user AND h.metric_date BETWEEN public.night_of(p_end - make_interval(hours => lookback)) - 1 AND v_night
       AND h.sleep_start IS NOT NULL AND h.sleep_start <= p_end
    UNION ALL
    SELECT s.sleep_onset_at,
           coalesce(s.fired_at, CASE WHEN s.status IN ('done','cancelled','fired','expired') THEN s.updated_at END, 'infinity')
      FROM public.smart_wake_sessions s
     WHERE s.user_id = p_user AND s.sleep_onset_at IS NOT NULL
       AND s.sleep_onset_at <= p_end AND s.sleep_onset_at > p_end - interval '36 hours'
  ) x WHERE s1 > s0;

  SELECT array_agg(tstzrange(w0, w1, '[)')) INTO v_work FROM (
    SELECT coalesce(w.detected_start, w.started_at) - interval '10 minutes' w0,
           coalesce(w.detected_end, w.ended_at, w.started_at + make_interval(secs => coalesce(w.duration_sec, 3600)))
             + interval '45 minutes' w1
      FROM public.workout_sessions w
     WHERE w.user_id = p_user AND w.started_at <= p_end AND w.started_at > p_end - make_interval(hours => lookback + 6)
  ) x WHERE w1 > w0;
  v_sleep := coalesce(v_sleep, '{}'); v_work := coalesce(v_work, '{}');

  -- forward pass over the last lookback hours; same input gives the same answer (replayable)
  FOR r IN SELECT * FROM public.drunk_hr_floor(p_user, p_end - make_interval(hours => lookback), p_end) ORDER BY bkt LOOP
    v_slot := (extract(hour from r.bkt AT TIME ZONE 'Europe/Berlin') * 2
               + (extract(minute from r.bkt AT TIME ZONE 'Europe/Berlin') >= 30)::int)::int;
    v_h := extract(hour from r.bkt AT TIME ZONE 'Europe/Berlin')::int;
    v_el := r.floor_bpm - v_base[v_slot + 1];
    v_asleep := (r.bkt <@ ANY(v_sleep)) AND v_el < e0;
    v_active := v_el > act_el OR (r.bkt <@ ANY(v_work));
    v_dt := CASE WHEN v_pt IS NULL THEN 5 ELSE extract(epoch from r.bkt - v_pt) / 60 END;
    v_pt := r.bkt;
    IF NOT v_active THEN
      v_L := CASE WHEN (v_h >= ev_from OR v_h < ev_to) AND NOT v_asleep
                  THEN greatest(0, least(1, (v_el - e0) / (e1 - e0))) * 100 ELSE 0 END;
      IF v_L > v_A THEN v_A := v_A + (v_L - v_A) * (1 - exp(-least(v_dt, 60) / tau));
      ELSE v_A := greatest(v_L, v_A - k * v_dt / 60); END IF;
    END IF;
    v_raw := least(4, floor(v_A / 20))::int;
    IF NOT v_asleep THEN                                  -- stage frozen while asleep: no change, no push
      IF v_raw > v_stage THEN v_stage := v_raw;
      ELSIF v_A < 20 * v_stage - hyst THEN v_stage := least(4, floor((v_A + hyst) / 20))::int; END IF;
    END IF;
    IF public.night_of(r.bkt) = v_night THEN
      -- only sleep that began this night (21:00-08:00) ends it; a lie-in past 08:00 belongs to the night before
      IF v_asleep AND (v_h >= 21 OR v_h < ev_to) THEN v_slept := true; END IF;
      IF v_A > v_peak THEN v_peak := v_A; v_peak_at := r.bkt; END IF;
      IF v_first20 IS NULL AND v_A >= 20 THEN v_first20 := r.bkt; END IF;
    END IF;
    IF r.bkt <= p_end - interval '30 minutes' THEN v_A30 := v_A; END IF;
    v_last_bkt := r.bkt; v_last_med := r.med; v_last_floor := r.floor_bpm;
    v_last_base := v_base[v_slot + 1]; v_last_el := v_el;
  END LOOP;

  SELECT max(recorded_at),
         count(DISTINCT date_trunc('minute', recorded_at)) FILTER (WHERE recorded_at > p_end - interval '30 minutes')
    INTO v_last, v_cov
    FROM public.realtime_health
   WHERE user_id = p_user AND recorded_at <= p_end AND recorded_at > p_end - interval '3 hours'
     AND heart_rate BETWEEN 30 AND 220;
  v_age := round((extract(epoch from p_end - v_last) / 60)::numeric, 1);
  v_cov := least(1, coalesce(v_cov, 0) / 30.0);

  -- a peak no sober evening reached. vr_open_at can set a lower bar in VR, but holds at the same 60 until sober VR
  -- evenings are measured (v238). Nothing here writes alcohol_flags; drink_nights.opened_at makes the night count (v237).
  v_src := CASE WHEN v_flag THEN 'tap'
                WHEN v_closed OR NOT auto_open THEN NULL
                WHEN v_latched IS NOT NULL THEN v_latched
                WHEN v_peak >= auto_at THEN 'heart_rate'
                WHEN v_vr AND v_A >= vr_at AND NOT v_slept THEN 'vr' END;
  v_open := v_src IS NOT NULL;
  v_asleep := v_asleep AND v_last_bkt > p_end - interval '15 minutes';
  -- gated = the phone stays silent: not tapped, asleep, or awake again after tonight's sleep (no wake-up ping).
  -- An automatic detection never pushes; only the app card and the avatar show it.
  v_gated := NOT v_flag OR v_asleep OR v_slept;
  v_reason := CASE WHEN v_last IS NULL OR v_age > stale THEN 'no_live_signal'
                   WHEN v_asleep THEN 'asleep'
                   WHEN v_slept THEN 'after_sleep'
                   WHEN v_flag THEN 'drinking_tonight'
                   WHEN v_open THEN 'auto_opened'
                   ELSE 'not_flagged' END;
  v_conf := round((v_cov * CASE WHEN v_flag THEN 0.75 WHEN v_open THEN 0.6 ELSE 0.45 END)::numeric, 2);

  IF v_reason = 'no_live_signal' THEN
    -- a backlog that has not landed yet is never scored as now
    v_out := jsonb_build_object('experimental', true, 'detector', 'drunk', 'model', 'hr_floor_v236', 'ts', p_end,
      'gated', v_gated, 'alcohol_mode', v_flag, 'stage', NULL, 'label', 'unknown', 'confidence', 0,
      'detected', v_open, 'source', v_src, 'vr', v_vr,
      'reason', v_reason, 'data_age_min', v_age, 'as_of', v_last,
      'last_intensity', round(v_A), 'peak_tonight', round(v_peak), 'note', v_note);
  ELSE
    v_out := jsonb_build_object('experimental', true, 'detector', 'drunk', 'model', 'hr_floor_v236', 'ts', p_end,
      'gated', v_gated, 'alcohol_mode', v_flag, 'reason', v_reason,
      'detected', v_open, 'source', v_src, 'vr', v_vr,
      'promille', round(v_A * ppp, 2), 'promille_basis', v_basis,
      'promille_range', jsonb_build_array(round(greatest(0, v_A - 25) * ppp, 2), round(least(100, v_A + 25) * ppp, 2)),
      'stage', v_stage, 'label', v_labels[v_stage + 1], 'intensity', round(v_A),
      'raw_stage', v_raw, 'raw_label', v_labels[coalesce(v_raw, 0) + 1],
      'range', jsonb_build_array(greatest(0, round(v_A) - 25), least(100, round(v_A) + 25)),
      'trend', CASE WHEN v_A30 IS NULL THEN NULL WHEN v_A - v_A30 > 5 THEN 'rising'
                    WHEN v_A30 - v_A > 5 THEN 'falling' ELSE 'steady' END,
      'peak_tonight', round(v_peak), 'peak_at', v_peak_at, 'first_buzzed_at', v_first20,
      'clear_by_if_you_stop', CASE WHEN v_A > 5 THEN p_end + make_interval(secs => ((v_A - 5) / k * 3600)::double precision) END,
      'suspected', v_A >= suspect_at,
      'asleep', v_asleep, 'slept_tonight', v_slept,
      'confidence', v_conf,
      'hr', round(v_last_med, 1), 'floor_hr', round(v_last_floor, 1),
      'baseline_hr', round(v_last_base, 1), 'hr_rise', round(v_last_el, 1), 'elevation_bpm', round(v_last_el, 1),
      'quality', jsonb_build_object('score', v_cov, 'coverage_frac', v_cov),
      'data_age_min', v_age, 'as_of', v_last,
      'note', v_note);
  END IF;

  IF p_persist THEN
    INSERT INTO public.biostate_state(user_id, detector, updated_at, committed_stage, committed_value, committed_at,
                                      raw_stage, raw_since, confidence, experimental, payload)
    VALUES (p_user, 'drunk', now(), (v_out->>'stage')::int, round(v_A, 1), p_end,
            (v_out->>'raw_stage')::int, v_first20, v_conf, true, v_out)
    ON CONFLICT (user_id, detector) DO UPDATE SET updated_at = now(), committed_stage = EXCLUDED.committed_stage,
      committed_value = EXCLUDED.committed_value, committed_at = EXCLUDED.committed_at, raw_stage = EXCLUDED.raw_stage,
      raw_since = EXCLUDED.raw_since, confidence = EXCLUDED.confidence, payload = EXCLUDED.payload;
  END IF;
  RETURN v_out;
END $function$;

CREATE OR REPLACE FUNCTION public.refresh_drunk_baseline(p_user uuid DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, p_days integer DEFAULT 35)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rhr_cut numeric; v_total int; v_late numeric; v_late_n int; v_measured int;
BEGIN
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY resting_hr) + 4 INTO v_rhr_cut
    FROM public.health_metrics
   WHERE user_id = p_user AND metric_date >= current_date - p_days AND night_data = 'complete' AND resting_hr > 0;

  DROP TABLE IF EXISTS pg_temp._drunk_base;
  CREATE TEMP TABLE _drunk_base ON COMMIT DROP AS
  WITH f AS (
    SELECT f.bkt, f.floor_bpm,
           (extract(hour from f.bkt AT TIME ZONE 'Europe/Berlin') * 2
             + (extract(minute from f.bkt AT TIME ZONE 'Europe/Berlin') >= 30)::int)::int slot,
           public.night_of(f.bkt) nt
    FROM public.drunk_hr_floor(p_user, now() - make_interval(days => p_days), now()) f
  )
  SELECT f.slot, f.floor_bpm FROM f
  LEFT JOIN public.health_metrics h ON h.user_id = p_user AND h.metric_date = f.nt
  WHERE f.slot NOT BETWEEN 12 AND 27                                -- 06:00-13:59 is not evening
    AND NOT public.drinking_tapped_night(p_user, f.nt)              -- his own tap, never detector output
    AND NOT EXISTS (SELECT 1 FROM public.health_metrics sl WHERE sl.user_id = p_user AND sl.metric_date = f.nt - 1
                     AND sl.sleep_hours < 6.5)                       -- v238: short sleep lifts next-day HR
    AND NOT EXISTS (SELECT 1 FROM public.drink_nights dn            -- nights he, a breath reading or the morning settled
                    WHERE dn.user_id = p_user AND dn.night = f.nt AND dn.label IN ('drinking', 'uncertain'))
    AND coalesce(h.alcohol_drinks_est, 0) < 1
    AND coalesce(h.resting_hr, 0) < coalesce(v_rhr_cut, 999)        -- next night's RHR not raised
    AND NOT EXISTS (SELECT 1 FROM public.health_metrics h2
                    WHERE h2.user_id = p_user AND h2.metric_date BETWEEN f.nt - 1 AND f.nt
                      AND f.bkt >= h2.sleep_start AND f.bkt < h2.sleep_end)
    AND NOT EXISTS (SELECT 1 FROM public.workout_sessions w
                    WHERE w.user_id = p_user
                      AND f.bkt >= coalesce(w.detected_start, w.started_at) - interval '10 minutes'
                      AND f.bkt <  coalesce(w.detected_end, w.ended_at,
                                            w.started_at + make_interval(secs => coalesce(w.duration_sec, 3600)))
                                   + interval '45 minutes');

  SELECT count(*), count(*) FILTER (WHERE slot BETWEEN 42 AND 47),
         percentile_cont(0.5) WITHIN GROUP (ORDER BY floor_bpm) FILTER (WHERE slot BETWEEN 42 AND 47)
    INTO v_total, v_late_n, v_late FROM _drunk_base;

  IF v_total < 200 OR v_late IS NULL THEN
    RETURN jsonb_build_object('updated', false, 'reason', 'too_little_sober_data', 'buckets', v_total);
  END IF;

  -- 16:00-24:00 measured where there are >= 12 buckets; everything else (after midnight, where being
  -- awake mostly means drinking, and the daytime) uses his pooled 21:00-24:00 floor
  INSERT INTO public.drunk_floor_baseline(user_id, slot, floor_bpm, n_buckets, source, updated_at)
  SELECT p_user, s.slot,
         CASE WHEN s.slot >= 32 AND coalesce(p.n, 0) >= 12 THEN round(p.p50::numeric, 1) ELSE round(v_late::numeric, 1) END,
         CASE WHEN s.slot >= 32 AND coalesce(p.n, 0) >= 12 THEN p.n ELSE v_late_n END,
         CASE WHEN s.slot >= 32 AND coalesce(p.n, 0) >= 12 THEN 'measured' ELSE 'late_pool' END,
         now()
  FROM generate_series(0, 47) s(slot)
  LEFT JOIN (SELECT slot, count(*)::int n, percentile_cont(0.5) WITHIN GROUP (ORDER BY floor_bpm) p50
             FROM _drunk_base GROUP BY slot) p USING (slot)
  ON CONFLICT (user_id, slot) DO UPDATE
    SET floor_bpm = EXCLUDED.floor_bpm, n_buckets = EXCLUDED.n_buckets,
        source = EXCLUDED.source, updated_at = EXCLUDED.updated_at;

  GET DIAGNOSTICS v_measured = ROW_COUNT;
  RETURN jsonb_build_object('updated', true, 'buckets', v_total, 'late_floor', round(v_late::numeric, 1),
    'measured_slots', (SELECT count(*) FROM public.drunk_floor_baseline WHERE user_id = p_user AND source = 'measured'));
END $function$;

UPDATE public.biostate_config SET cfg = jsonb_set(cfg, '{drunk,hr_floor,vr_open_at}', '60'::jsonb)
 WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff';

COMMIT;
