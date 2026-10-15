-- v218: the sleep need grows while he heals and when his body is under measurable load, the alarm aims at
-- the full need instead of 30 min before it, and the bedtime plan reads the same number as the alarm.
--
-- 2026-10-14: the window opened at need - 30 min asleep and fired on the first light minute. Replayed on 18 complete
-- nights since 08-15 that minute was already non-deep on 17, so the alarm rang 30 min short almost every night
-- (rang with half an hour of the need still unslept). Two need functions also disagreed: the alarm and the bedtime
-- plan aimed at different numbers.
--
-- What changes:
--   recovery_events     dated healing periods (surgery, injury, illness). Each adds extra_h of need on day 0 and
--                       fades linearly to nothing at taper_days. Rows are personal and live only in the database.
--   sleep_load()        how far the last 3 sober nights' HRV and resting HR sit from a healthy baseline, in SDs.
--                       The baseline is frozen before an active recovery event (a rolling one absorbs the dip it is
--                       meant to measure), otherwise the 60 nights ending a week ago.
--   compute_sleep_need  + d_heal (event taper) + d_load (0.15 h at 1 SD, +0.3 h per further SD, max 0.5 h; a 0.5 SD bar
--                       fired on a third of ordinary days because HRV drifts over months); load replaces the old
--                       +0.15 h "HRV under 90% of a rolling baseline" bump. Healing + load together max 1 h; the
--                       target still caps at 9.5 h asleep. The sleep-efficiency bump is dropped: since v213 the
--                       alarm counts minutes asleep, so a restless night already gets more time in bed.
--   compute_sleep_debt  each night's shortfall is counted against base + that night's healing, not base alone.
--   smart_wake_evaluate the light-sleep window opens at the full need (sleep_need_settings.window_lead_min, 0).
--   target_sleep_duration returns compute_sleep_need's number, so "lights out by" and the alarm agree.
--   refresh_optimal_sleep_prior skips nights inside a recovery event, so a healing stretch cannot move his base.
--   arm_smart_wake      stores d_heal, d_load and the need breakdown on the session.
--
-- Switch back without a rollback: UPDATE sleep_need_settings SET model='v217', window_lead_min=30 WHERE user_id=...;
-- Full rollback: supabase-migration-v218-rollback.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS public.recovery_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('surgery','injury','illness')),
  started_on  date NOT NULL,
  extra_h     numeric NOT NULL DEFAULT 0.75 CHECK (extra_h BETWEEN 0 AND 1.5),
  taper_days  int NOT NULL DEFAULT 42 CHECK (taper_days BETWEEN 1 AND 120),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS recovery_events_user_idx ON public.recovery_events (user_id, started_on);
COMMENT ON COLUMN public.recovery_events.started_on IS
  'First morning after the event (the metric_date of the first night it affects); that night gets the full extra_h.';
ALTER TABLE public.recovery_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS own_recovery_events ON public.recovery_events;
CREATE POLICY own_recovery_events ON public.recovery_events FOR ALL
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE TABLE IF NOT EXISTS public.sleep_need_settings (
  user_id          uuid PRIMARY KEY,
  model            text NOT NULL DEFAULT 'v218' CHECK (model IN ('v217','v218')),
  window_lead_min  int  NOT NULL DEFAULT 0 CHECK (window_lead_min BETWEEN 0 AND 60),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.sleep_need_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS own_sleep_need_settings ON public.sleep_need_settings;
CREATE POLICY own_sleep_need_settings ON public.sleep_need_settings FOR ALL
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

ALTER TABLE public.smart_wake_sessions
  ADD COLUMN IF NOT EXISTS d_heal numeric,
  ADD COLUMN IF NOT EXISTS d_load numeric,
  ADD COLUMN IF NOT EXISTS need_note text;

CREATE OR REPLACE FUNCTION public.sleep_need_model(p_user_id uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  SELECT COALESCE((SELECT model FROM sleep_need_settings WHERE user_id = p_user_id), 'v218');
$function$;

-- extra need from dated healing periods on the night that ends on p_on: linear fade from extra_h to 0
CREATE OR REPLACE FUNCTION public.recovery_heal_h(p_user_id uuid, p_on date)
 RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  SELECT round(LEAST(1.0, COALESCE(sum(e.extra_h * GREATEST(0, 1 - (p_on - e.started_on)::numeric / e.taper_days)), 0)), 2)
    FROM recovery_events e
   WHERE e.user_id = p_user_id AND p_on >= e.started_on AND p_on < e.started_on + e.taper_days;
$function$;

-- body load: last 3 sober complete nights against a healthy baseline, in SDs (HRV down and resting HR up)
CREATE OR REPLACE FUNCTION public.sleep_load(p_user_id uuid, p_date date)
 RETURNS TABLE(z numeric, hrv_recent numeric, hrv_base numeric, rhr_recent numeric, rhr_base numeric, nights int, base_from date, base_to date)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE ev date; b0 date; b1 date; hb numeric; hsd numeric; rb numeric; rsd numeric; nb int;
  hr numeric; rr numeric; nr int;
BEGIN
  SELECT max(e.started_on) INTO ev FROM recovery_events e
   WHERE e.user_id = p_user_id AND p_date >= e.started_on AND p_date < e.started_on + e.taper_days;
  IF ev IS NOT NULL THEN b0 := ev - 60; b1 := ev - 1;
  ELSE b0 := p_date - 68; b1 := p_date - 8; END IF;

  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY h.hrv_avg), stddev(h.hrv_avg),
         percentile_cont(0.5) WITHIN GROUP (ORDER BY h.resting_hr), stddev(h.resting_hr), count(*)
    INTO hb, hsd, rb, rsd, nb
    FROM health_metrics h
   WHERE h.user_id = p_user_id AND h.metric_date BETWEEN b0 AND b1
     AND h.sleep_complete AND COALESCE(h.excluded, false) = false AND COALESCE(h.alcohol_drinks_est, 0) < 1
     AND h.hrv_avg BETWEEN 10 AND 200 AND h.resting_hr > 30;

  SELECT avg(x.hrv_avg), avg(x.resting_hr), count(*) INTO hr, rr, nr FROM (
    SELECT h.hrv_avg, h.resting_hr FROM health_metrics h
     WHERE h.user_id = p_user_id AND h.metric_date BETWEEN p_date - 5 AND p_date - 1
       AND h.sleep_complete AND COALESCE(h.excluded, false) = false AND COALESCE(h.alcohol_drinks_est, 0) < 1
       AND h.hrv_avg BETWEEN 10 AND 200 AND h.resting_hr > 30
     ORDER BY h.metric_date DESC LIMIT 3) x;

  hrv_base := round(hb, 1); rhr_base := round(rb, 1); hrv_recent := round(hr, 1); rhr_recent := round(rr, 1);
  nights := nr; base_from := b0; base_to := b1;
  IF nb < 10 OR nr < 2 OR COALESCE(hsd, 0) <= 0 OR COALESCE(rsd, 0) <= 0 THEN z := NULL;
  ELSE z := round(GREATEST(0, ((hb - hr) / hsd + (rr - rb) / rsd) / 2), 2); END IF;
  RETURN NEXT;
END;$function$;

CREATE OR REPLACE FUNCTION public.compute_sleep_debt(p_user_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE base numeric; debt numeric := 0; nights int := 0; win int := 7; r record; need numeric; heal boolean;
  today date := (now() AT TIME ZONE 'Europe/Berlin')::date;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);
  heal := sleep_need_model(p_user_id) = 'v218';

  FOR r IN
    SELECT metric_date, sleep_hours FROM health_metrics
     WHERE user_id=p_user_id
       AND sleep_hours > 0
       AND sleep_complete IS NOT FALSE
       AND COALESCE(excluded, false) = false
       AND metric_date > today - win AND metric_date <= today
     ORDER BY metric_date
  LOOP
    nights := nights + 1;
    -- v218: a night is short against what he needed that night, healing included
    need := base + CASE WHEN heal THEN recovery_heal_h(p_user_id, r.metric_date) ELSE 0 END;
    IF r.sleep_hours < need THEN
      debt := debt + LEAST(2, need - r.sleep_hours);
    ELSE
      debt := GREATEST(0, debt - LEAST(1, 0.5 * (r.sleep_hours - need)));
    END IF;
  END LOOP;

  IF nights < 3 THEN RETURN NULL; END IF;          -- too little observed to claim a number
  RETURN round(debt, 2);
END;$function$
;

DROP FUNCTION IF EXISTS public.compute_sleep_need(uuid, date);
CREATE FUNCTION public.compute_sleep_need(p_user_id uuid, p_date date DEFAULT (((now() AT TIME ZONE 'Europe/Berlin'::text))::date + 1))
 RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_quality numeric, d_circadian numeric, debt_raw numeric, note text, d_heal numeric, d_load numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  base numeric; debt numeric; dd numeric := 0; ds numeric := 0; dq numeric := 0; dc numeric := 0;
  ystrain numeric; strainbase numeric; yhrv numeric; hrvbase numeric;
  yeff numeric; ydeep numeric; ycons numeric; v_last date;
  deepnorm numeric := 105;
  v_model text; dh numeric := 0; dl numeric := 0; ld record; ev record;
  parts text;
BEGIN
  v_model := sleep_need_model(p_user_id);
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- Homeostatic debt: repayment is partial (~25%/night), and the curve saturates
  -- smoothly toward 0.75 instead of clipping there, so the term keeps discriminating
  -- between 4h owed and 14h owed.
  debt := compute_sleep_debt(p_user_id);
  IF debt IS NOT NULL THEN
    dd := round(0.75 * (1 - exp(-debt / 7.0)), 2);
  END IF;

  SELECT metric_date, strain_score, hrv_avg, sleep_efficiency_pct, deep_sleep_min
    INTO v_last, ystrain, yhrv, yeff, ydeep
    FROM health_metrics
   WHERE user_id=p_user_id AND sleep_hours > 0
   ORDER BY metric_date DESC LIMIT 1;

  -- Strain: yesterday's load vs his 14-day baseline. strain_score pegs at Whoop's
  -- 21.0 ceiling on ~46% of days, so this channel is weak by construction; the 0.4
  -- cap keeps a saturated input from dominating.
  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  IF ystrain IS NOT NULL AND strainbase > 0 AND ystrain > strainbase THEN
    ds := ds + LEAST(0.4, 0.4 * ((ystrain / strainbase) - 1));
  END IF;
  hrvbase := COALESCE(
    (SELECT baseline_hrv_avg FROM current_state WHERE user_id=p_user_id),
    (SELECT avg(hrv_avg) FROM health_metrics WHERE user_id=p_user_id AND hrv_avg>0 AND metric_date >= CURRENT_DATE - 14));
  -- v218: the HRV bump moved into the load term below, measured against a baseline that cannot absorb the dip
  IF v_model = 'v217' AND yhrv IS NOT NULL AND hrvbase IS NOT NULL AND yhrv < 0.90 * hrvbase THEN ds := ds + 0.15; END IF;
  ds := round(LEAST(0.5, ds), 2);

  -- v218: the alarm counts minutes asleep (v213), so a restless night already runs longer; the efficiency bump counted it twice
  IF v_model = 'v217' AND yeff IS NOT NULL AND yeff < 85 THEN dq := dq + LEAST(0.4, 0.4*((85-yeff)/15.0)); END IF;
  IF ydeep IS NOT NULL AND ydeep < deepnorm - 15 THEN dq := dq + 0.15; END IF;
  dq := round(LEAST(0.5, dq), 2);

  -- Circadian: measured off his actual bedtime scatter, not the dead column.
  ycons := sleep_consistency_score(p_user_id, p_date);  -- v217: the 14 nights before tonight, last night included
  IF ycons IS NOT NULL AND ycons < 70 THEN
    dc := round(LEAST(0.25, 0.25 * ((70 - ycons) / 40.0)), 2);
  END IF;

  IF v_model = 'v218' THEN
    -- healing: dated events fading to nothing; load: measured HRV/resting-HR deviation, 0.15 h at 1 SD, +0.3 h per further SD
    dh := recovery_heal_h(p_user_id, p_date);
    SELECT * INTO ld FROM sleep_load(p_user_id, p_date);
    -- only past 1 SD: a 0.5 SD bar fired on a third of ordinary days (slow HRV drift, not load); 1 SD fires on ~5%
    IF ld.z IS NOT NULL AND ld.z >= 1.0 THEN dl := round(LEAST(0.5, 0.3 * (ld.z - 0.5)), 2); END IF;
    IF dh + dl > 1.0 THEN dl := GREATEST(0, 1.0 - dh); END IF;
  END IF;

  target_h    := round(LEAST(9.5, GREATEST(6.0, base + dd + ds + dq + dc + dh + dl)), 2);
  base_h      := base;  d_debt := dd;  d_strain := ds;  d_quality := dq;  d_circadian := dc;
  debt_raw    := round(debt, 2);  d_heal := dh;  d_load := dl;

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || dd || ' debt (' || round(debt,1) || 'h owed)'; END IF;
  IF ds > 0 THEN parts := parts || ' +' || ds || ' strain'; END IF;
  IF dq > 0 THEN parts := parts || ' +' || dq || ' quality'; END IF;
  IF dc > 0 THEN parts := parts || ' +' || dc || ' circadian (bedtime scatter)'; END IF;
  IF dh > 0 THEN
    SELECT e.kind, (p_date - e.started_on) AS day_n, e.taper_days INTO ev FROM recovery_events e
     WHERE e.user_id = p_user_id AND p_date >= e.started_on AND p_date < e.started_on + e.taper_days
     ORDER BY e.started_on DESC LIMIT 1;
    parts := parts || ' +' || dh || ' healing (' || ev.kind || ', day ' || ev.day_n || ' of ' || ev.taper_days || ')';
  END IF;
  IF dl > 0 THEN
    parts := parts || ' +' || dl || ' body load (HRV ' || ld.hrv_recent || ' vs ' || ld.hrv_base
          || ', resting HR ' || ld.rhr_recent || ' vs ' || ld.rhr_base || ')';
  END IF;
  IF debt IS NULL THEN parts := parts || ' (debt unknown — too few observed nights)'; END IF;
  note := parts || ' -> aim for ' || target_h || 'h tonight';
  RETURN NEXT;
END;$function$
;
REVOKE ALL ON FUNCTION public.compute_sleep_need(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compute_sleep_need(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.target_sleep_duration_v217(p_user_id uuid, p_for_date date DEFAULT (((now() AT TIME ZONE 'Europe/Berlin'::text))::date + 1))
 RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_illness numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE base numeric; debt numeric; ystrain numeric; strainbase numeric;
        yrhr numeric; rhrmed numeric; yalc numeric; was_alcohol boolean;
        v_last date; dd numeric; ds numeric; di numeric; parts text;
BEGIN
  SELECT mu INTO base FROM personal_priors WHERE user_id=p_user_id AND param='optimal_sleep_hours';
  base := round(COALESCE(base, 8.0), 2);

  -- Debt: gentle. Repay over multiple nights at his sweet spot, not one big night.
  -- compute_sleep_debt now returns NULL when the week is too thinly observed to
  -- claim a number, so this must not propagate a NULL into target_h. Same
  -- saturating-but-never-pinned curve as compute_sleep_need, scaled to this 0.5 cap.
  debt := compute_sleep_debt(p_user_id);
  dd := CASE WHEN debt IS NULL THEN 0 ELSE round(0.5 * (1 - exp(-debt / 7.0)), 2) END;

  -- Read the MOST RECENT completed night (not CURRENT_DATE-1, which lags a day
  -- when the plan is computed in the evening after today's recompute). This is
  -- the bug that read the alcohol night's RHR instead of last night's recovered one.
  SELECT metric_date, resting_hr, strain_score, alcohol_impact
    INTO v_last, yrhr, ystrain, yalc
    FROM health_metrics
   WHERE user_id=p_user_id AND sleep_hours > 0
   ORDER BY metric_date DESC LIMIT 1;

  SELECT avg(strain_score) INTO strainbase FROM health_metrics
   WHERE user_id=p_user_id AND strain_score > 0 AND metric_date >= CURRENT_DATE - 14;
  ds := CASE WHEN ystrain IS NOT NULL AND strainbase IS NOT NULL AND ystrain > strainbase*1.15
             THEN 0.3 ELSE 0 END;

  -- Was the most recent night an alcohol night? Then an elevated RHR is a
  -- hangover, not illness — do NOT prescribe extra sleep for it.
  was_alcohol := COALESCE(yalc,0) >= 1;
  IF NOT was_alcohol AND v_last IS NOT NULL THEN
    BEGIN
      was_alcohol := detect_overnight_alcohol(p_user_id, v_last, 'Europe/Berlin');
    EXCEPTION WHEN OTHERS THEN was_alcohol := false;
    END;
  END IF;

  SELECT median INTO rhrmed FROM personal_baselines
   WHERE user_id=p_user_id AND metric='resting_hr' AND window_days=30;
  di := CASE WHEN yrhr IS NOT NULL AND rhrmed IS NOT NULL AND yrhr > rhrmed + 3 AND NOT was_alcohol
             THEN 0.5 ELSE 0 END;

  -- Clamp tightened: never push him past base+0.75 — his data says oversleeping
  -- (circadian drift) makes him groggier, not more rested.
  target_h := ROUND(LEAST(GREATEST(base + dd + ds + di, base - 0.5), base + 0.75), 2);
  base_h := base; d_debt := ROUND(dd,2); d_strain := ds; d_illness := di;

  parts := 'base ' || base || 'h';
  IF dd > 0 THEN parts := parts || ' +' || round(dd,1) || ' debt'; END IF;
  IF ds > 0 THEN parts := parts || ' +0.3 high strain'; END IF;
  IF di > 0 THEN parts := parts || ' +0.5 illness signs'; END IF;
  IF was_alcohol AND yrhr IS NOT NULL AND rhrmed IS NOT NULL AND yrhr > rhrmed + 3 THEN
    parts := parts || ' (skipped illness bump — that was the alcohol)';
  END IF;
  note := parts || ' = aim for ' || target_h || 'h';
  RETURN NEXT;
END;$function$
;

CREATE OR REPLACE FUNCTION public.target_sleep_duration(p_user_id uuid, p_for_date date DEFAULT (((now() AT TIME ZONE 'Europe/Berlin'::text))::date + 1))
 RETURNS TABLE(target_h numeric, base_h numeric, d_debt numeric, d_strain numeric, d_illness numeric, note text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
  -- v218: one number for tonight. The bedtime plan used its own formula and disagreed with the alarm.
  -- d_illness feeds compute_sleep_readiness's 'illness signs': only measured body load, never the healing taper.
  IF sleep_need_model(p_user_id) = 'v217' THEN
    RETURN QUERY SELECT * FROM target_sleep_duration_v217(p_user_id, p_for_date);
    RETURN;
  END IF;
  RETURN QUERY
    SELECT c.target_h, c.base_h, c.d_debt, c.d_strain + c.d_quality + c.d_circadian, c.d_load, c.note
      FROM compute_sleep_need(p_user_id, p_for_date) c;
END;$function$
;

REVOKE ALL ON FUNCTION public.sleep_need_model(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sleep_need_model(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.recovery_heal_h(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.recovery_heal_h(uuid, date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.sleep_load(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sleep_load(uuid, date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.target_sleep_duration_v217(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.target_sleep_duration_v217(uuid, date) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.target_sleep_duration(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.target_sleep_duration(uuid, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.refresh_optimal_sleep_prior(p_user_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE best_h numeric;
BEGIN
  -- v153 (finding #1): sample-weighted dose-response over PHYSIOLOGICAL durations only.
  -- The old code took argmax-of-noisy-bucket (ORDER BY median-recovery DESC LIMIT 1,
  -- gated only by n>=3), which learned 11h as "optimal" via reverse causation: he sleeps
  -- 10-11h on rest/recovery days, so those days show high recovery. Fix:
  --   (a) restrict to the 5-9h physiological band (hard-clamps the oversleep confound out),
  --   (b) de-confound by dropping illness / alcohol nights,
  --   (c) require n>=8 per bucket so a 7-night bucket can't win,
  --   (d) take the KNEE — the SMALLEST duration whose median recovery is within 3 pts of the
  --       peak bucket — instead of the argmax, so the plateau onset is chosen, not the max,
  --   (e) hard-clamp <=9h as a final ceiling.
  SELECT min(hrs) INTO best_h
  FROM (
    SELECT hrs, mr, max(mr) OVER () AS peak
    FROM (
      SELECT round(sleep_hours) AS hrs,
             count(*) AS c,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY recovery_score) AS mr
      FROM health_metrics
      WHERE user_id=p_user_id AND sleep_hours > 0 AND recovery_score > 0
        AND round(sleep_hours) BETWEEN 5 AND 9
        AND COALESCE(illness_risk,0) < 1
        AND COALESCE(alcohol_impact,0) < 1
        AND metric_date >= CURRENT_DATE - 120
        AND NOT EXISTS (SELECT 1 FROM recovery_events e WHERE e.user_id = p_user_id
                         AND metric_date >= e.started_on AND metric_date < e.started_on + e.taper_days)  -- v218
      GROUP BY round(sleep_hours)
      HAVING count(*) >= 8
    ) b
  ) z
  WHERE mr >= peak - 3;

  IF best_h IS NOT NULL THEN
    best_h := LEAST(best_h, 9);
    PERFORM update_personal_prior(p_user_id, 'optimal_sleep_hours', best_h, 0.6);
  END IF;
  RETURN best_h;
END;$function$
;

CREATE OR REPLACE FUNCTION public.arm_smart_wake(p_user_id uuid, p_latest_wake timestamp with time zone DEFAULT NULL::timestamp with time zone, p_prep_min integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  sid uuid; floor_h numeric; note text; dl_label text; tz text := 'Europe/Berlin';
  v_target numeric; v_base numeric; v_dd numeric; v_ds numeric; v_dq numeric; v_dc numeric; v_note text;
  v_dh numeric; v_dl numeric;
  v_below_floor boolean := false; v_floor_reach timestamptz;
BEGIN
  SELECT csn.target_h, csn.base_h, csn.d_debt, csn.d_strain, csn.d_quality, csn.d_circadian, csn.note, csn.d_heal, csn.d_load
    INTO v_target, v_base, v_dd, v_ds, v_dq, v_dc, v_note, v_dh, v_dl
  FROM compute_sleep_need(p_user_id, ((now() AT TIME ZONE tz)::date + 1)) csn;

  -- one live session at a time: retire any prior active one.
  UPDATE smart_wake_sessions
     SET status='cancelled', updated_at=now(),
         notes = COALESCE(notes,'') || ' [superseded by new arm ' || to_char(now(),'HH24:MI') || ']'
   WHERE user_id=p_user_id AND status IN ('armed','asleep','ready');

  floor_h := round(CASE WHEN p_latest_wake IS NULL THEN GREATEST(7.0, 0.7 * v_target) ELSE GREATEST(6.0, 0.7 * v_target) END, 2);

  -- Sub-floor deadline guard: onset ~ now at arm time, so earliest possible wake ~ now + floor_h.
  -- If the requested deadline lands before that, the safety floor WILL override it (silent ~defer).
  -- Surface it so a real "up by X" (flight/train) isn't quietly missed.
  IF p_latest_wake IS NOT NULL THEN
    v_floor_reach := now() + (floor_h || ' hours')::interval;
    v_below_floor := p_latest_wake < v_floor_reach;
  END IF;

  INSERT INTO smart_wake_sessions(
    user_id, armed_at, latest_wake_at, prep_min,
    target_h, base_h, d_debt, d_strain, d_quality, d_circadian, d_heal, d_load, need_note, status)
  VALUES (p_user_id, now(), p_latest_wake, p_prep_min,
    v_target, v_base, v_dd, v_ds, v_dq, v_dc, v_dh, v_dl, v_note, 'armed')
  RETURNING id INTO sid;

  IF p_latest_wake IS NOT NULL THEN
    dl_label := to_char(p_latest_wake AT TIME ZONE tz, 'HH24:MI');
    IF v_below_floor THEN
      note := 'Heads up: ' || dl_label || ' is sooner than my ' || floor_h || 'h minimum-sleep floor from when '
           || 'you''d fall asleep, so if you need to be up that early for something real, set a normal alarm too. '
           || 'Otherwise I''ll wake you as close to ' || dl_label || ' as I safely can, protecting the ' || floor_h
           || 'h floor first.';
    ELSE
      note := 'You need about ' || v_target || 'h tonight. I''ll start the clock the moment you actually fall '
           || 'asleep — not now — hold a hard floor of ' || floor_h || 'h so I never wake you short, then catch a '
           || 'light-sleep window near your ' || v_target || 'h target. Earlier only if you''ve genuinely banked the '
           || 'recovery. You''re up by ' || dl_label || ' no matter what.';
    END IF;
  ELSE
    note := 'You need about ' || v_target || 'h tonight. I''ll start the clock the moment you actually fall '
         || 'asleep — not now — hold a hard floor of ' || floor_h || 'h so I never wake you short, then catch a '
         || 'light-sleep window near your ' || v_target || 'h target. Earlier only if you''ve genuinely banked the '
         || 'recovery. No deadline set, so the latest is your target plus an hour, and never more than 10h after you fall asleep.';
  END IF;

  RETURN jsonb_build_object(
    'session_id', sid,
    'status', 'armed',
    'target_h', v_target,
    'base_h', v_base,
    'components', jsonb_build_object('debt',v_dd,'strain',v_ds,'quality',v_dq,'circadian',v_dc,'healing',v_dh,'load',v_dl),
    'safety_floor_h', floor_h,
    'latest_wake_at', CASE WHEN p_latest_wake IS NULL THEN NULL
                           ELSE to_char(p_latest_wake AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
    'latest_wake_label', dl_label,
    'deadline_below_floor', v_below_floor,
    'prep_min', p_prep_min,
    'note', note,
    'need_breakdown', v_note
  );
END;$function$
;

CREATE OR REPLACE FUNCTION public.smart_wake_evaluate(p_user_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS TABLE(session_id uuid, should_fire boolean, reason text, stage text, wake_score integer, deep_prob numeric, slept_h_so_far numeric, target_h numeric, earliest_wake_at timestamp with time zone, target_wake_at timestamp with time zone, backstop_at timestamp with time zone, recovery_pct numeric, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s record; v_onset timestamptz; v_target numeric; floor_h numeric;
  v_earliest timestamptz; v_target_wake timestamptz; v_backstop timestamptz;
  sw_wake boolean; sw_score int; sw_dp numeric; sw_reason text;
  v_stage text; v_slept numeric;
  total_deep_min int; recent_hrv numeric; base_hrv numeric;
  hrv_rebound boolean; recovery_complete boolean; v_recpct numeric;
  v_should boolean := false; v_reason text; v_last_sample timestamptz;
  tz text := 'Europe/Berlin';
  v_need int; v_asleep int; v_aw6 int; v_n6 int; v_aw30 int; v_n30 int; v_deep4 int; v_aw4 int;
  v_alcohol boolean; v_last_min timestamptz; v_last_awake int; s5 record; s15 record;
  v_awake_now boolean; v_stopped boolean; v_light_ok boolean; v_blind_backstop timestamptz;
  v_last_any timestamptz; v_night_end timestamptz; v_night date;
  v_last_rt timestamptz; v_floor numeric; v_sleep_start timestamptz; v_cut boolean := false; v_was_awake boolean;
  v_lead int;
  v_aw60 int; v_n60 int; v_c6 int := 0; v_ch6 int := 0; v_c30 int := 0; v_ch30 int := 0; v_c60 int := 0; v_ch60 int := 0;
BEGIN
  SELECT * INTO s FROM smart_wake_sessions
   WHERE user_id=p_user_id AND smart_wake_sessions.status IN ('armed','asleep','ready')
   ORDER BY armed_at DESC LIMIT 1;

  IF s.id IS NULL THEN
    session_id:=NULL; should_fire:=false; reason:='no_armed_session'; status:='none';
    RETURN NEXT; RETURN;
  END IF;

  v_target := COALESCE(s.target_h, 8.0);
  v_onset  := s.sleep_onset_at;

  -- v175: floor is 7h when no clock deadline was set (never wake him short on a free morning).
  -- With an explicit deadline the old 6h floor stands so a real flight/train alarm still lands.
  floor_h := CASE WHEN s.latest_wake_at IS NULL
                  THEN GREATEST(7.0, 0.7 * v_target)
                  ELSE GREATEST(6.0, 0.7 * v_target) END;

  -- ---- Onset detection / transition ----
  IF v_onset IS NULL THEN
    v_onset := detect_live_sleep_onset(p_user_id, s.armed_at, p_now);
    IF v_onset IS NOT NULL THEN
      v_earliest    := v_onset + make_interval(mins => round(floor_h*60)::int);
      v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int);
      -- v175: default backstop follows the sleep need instead of a flat 9.5h, so there is always a
      -- real ~1h light-sleep hunting window after target instead of the 26 min a 9.06h target left.
      v_backstop    := COALESCE(s.latest_wake_at,
                         GREATEST(v_onset + interval '8 hours',
                                  v_onset + make_interval(mins => round((v_target + 1.0)*60)::int)));
      UPDATE smart_wake_sessions
         SET status='asleep', sleep_onset_at=v_onset,
             earliest_wake_at=v_earliest, target_wake_at=v_target_wake,
             backstop_at=v_backstop, updated_at=now()
       WHERE id=s.id;
    ELSE
      IF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at THEN
        session_id:=s.id; should_fire:=true; reason:='deadline_no_onset';
        stage:='unknown'; wake_score:=100; deep_prob:=NULL; slept_h_so_far:=NULL;
        target_h:=v_target; earliest_wake_at:=NULL; target_wake_at:=NULL;
        backstop_at:=s.latest_wake_at; recovery_pct:=NULL; status:=s.status;
        RETURN NEXT; RETURN;
      ELSIF p_now >= s.armed_at + interval '20 hours' THEN
        session_id:=s.id; should_fire:=false; reason:='expire_no_onset'; status:='armed';
        target_h:=v_target; RETURN NEXT; RETURN;
      ELSE
        session_id:=s.id; should_fire:=false; reason:='awaiting_onset'; status:='armed';
        target_h:=v_target; RETURN NEXT; RETURN;
      END IF;
    END IF;
  ELSE
    v_earliest    := s.earliest_wake_at;
    v_target_wake := s.target_wake_at;
    v_backstop    := s.backstop_at;
    IF v_earliest IS NULL THEN v_earliest := v_onset + make_interval(mins => round(floor_h*60)::int); END IF;
    IF v_target_wake IS NULL THEN v_target_wake := v_onset + make_interval(mins => round(v_target*60)::int); END IF;
    IF v_backstop IS NULL THEN
      v_backstop := COALESCE(s.latest_wake_at,
                      GREATEST(v_onset + interval '8 hours',
                               v_onset + make_interval(mins => round((v_target + 1.0)*60)::int)));
    END IF;
  END IF;

  -- v213: the clock counts minutes ASLEEP from the same stager as the morning summary (drinking-aware
  -- since v207), not wall time since onset. The need is learned from asleep hours, so the wall clock woke
  -- him ~50 min short and he slept on (7 of 21 fires in 60 days). Awake is checked at every step,
  -- including at the window end, and the app's stop / "I'm awake" log ends the session.
  v_slept := round(EXTRACT(epoch FROM (p_now - v_onset))/3600.0, 2);
  IF p_now < v_onset + interval '5 hours' THEN
    session_id:=s.id; should_fire:=false; reason:='safety_floor'; stage:='unknown';
    slept_h_so_far:=v_slept; target_h:=v_target; earliest_wake_at:=v_earliest;
    target_wake_at:=v_target_wake; backstop_at:=v_backstop; status:=COALESCE(s.status,'asleep');
    RETURN NEXT; RETURN;
  END IF;

  -- the night a minute belongs to runs 19:00 to 12:00 (Berlin), as in sleep_night_minutes
  v_night := ((p_now AT TIME ZONE tz) + interval '5 hours')::date;
  v_night_end := (v_night::text || ' 12:00:00')::timestamp AT TIME ZONE tz;

  -- v_last_any counts minutes before the stager's own onset too: data flowing, him not asleep yet, is not a dead strap
  SELECT count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage <> 'awake'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '6 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '6 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '30 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '30 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'deep'  AND m.n_m_ts > p_now - interval '4 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '4 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage = 'awake' AND m.n_m_ts > p_now - interval '60 minutes'),
         count(*) FILTER (WHERE NOT m.n_pre_onset AND m.n_m_ts > p_now - interval '60 minutes'),
         percentile_cont(0.10) WITHIN GROUP (ORDER BY m.n_hr) FILTER (WHERE NOT m.n_pre_onset AND m.n_stage <> 'awake'),
         min(m.n_m_ts) FILTER (WHERE NOT m.n_pre_onset),
         bool_or(m.n_alcohol), max(m.n_m_ts) FILTER (WHERE NOT m.n_pre_onset), max(m.n_m_ts)
    INTO v_asleep, v_aw6, v_n6, v_aw30, v_n30, v_deep4, v_aw4, v_aw60, v_n60, v_floor, v_sleep_start, v_alcohol, v_last_min, v_last_any
    FROM sleep_night_minutes(p_user_id, v_night) m
   WHERE m.n_m_ts <= p_now;
  v_asleep := COALESCE(v_asleep, 0);

  -- the stage of the last minutes the strap did send, for when it went quiet
  SELECT count(*) FILTER (WHERE m.n_stage = 'awake') INTO v_last_awake
    FROM sleep_night_minutes(p_user_id, v_night) m
   WHERE NOT m.n_pre_onset AND m.n_m_ts <= v_last_min AND m.n_m_ts > v_last_min - interval '6 minutes';


  -- v215: liveness comes from the strap's raw samples, not from the stager. The stager drops every minute after a
  -- wake it sees (15+ min of high heart rate once 4 h asleep), so its output going quiet means he is awake, not that
  -- the strap is off. 2026-10-13: he woke at 06:22 for ~15 min, the stager cut the tail, v213 read a dead strap after
  -- 5 h asleep and closed the night with no ring; he slept on to 09:45.
  SELECT max(r.recorded_at) INTO v_last_rt FROM realtime_health r
   WHERE r.user_id = p_user_id AND r.recorded_at > GREATEST(v_onset, p_now - interval '14 hours')
     AND r.recorded_at <= p_now AND r.heart_rate > 30;
  v_cut := v_last_rt >= p_now - interval '15 minutes' AND v_last_min IS NOT NULL
           AND v_last_min < p_now - interval '3 minutes';
  IF v_cut THEN
    -- the minutes the stager cut, judged the way it judges them: awake at the night's floor + 9 bpm
    SELECT count(*) FILTER (WHERE x.m > p_now - interval '6 minutes'),
           count(*) FILTER (WHERE x.m > p_now - interval '6 minutes' AND x.hr >= v_floor + 9),
           count(*) FILTER (WHERE x.m > p_now - interval '30 minutes'),
           count(*) FILTER (WHERE x.m > p_now - interval '30 minutes' AND x.hr >= v_floor + 9),
           count(*), count(*) FILTER (WHERE x.hr >= v_floor + 9)
      INTO v_c6, v_ch6, v_c30, v_ch30, v_c60, v_ch60
      FROM (SELECT date_trunc('minute', r.recorded_at) AS m, avg(r.heart_rate) AS hr FROM realtime_health r
             WHERE r.user_id = p_user_id AND r.recorded_at >= v_last_min + interval '1 minute'
               AND r.recorded_at > p_now - interval '60 minutes' AND r.recorded_at <= p_now AND r.heart_rate > 30
             GROUP BY 1) x;
  END IF;
  -- awake when the strap went quiet: the stager's last minutes say so, or raw data ran on 10+ min past its cut
  v_was_awake := COALESCE(v_last_awake, 0) >= 4
                 OR (v_last_rt IS NOT NULL AND v_last_min IS NOT NULL AND v_last_rt > v_last_min + interval '10 minutes');

  v_need := round(v_target * 60)::int;
  -- v218: the light-sleep window opens at the full need (was 30 min before it: rang 30 min short on 17 of 18 nights)
  SELECT ns.window_lead_min INTO v_lead FROM sleep_need_settings ns WHERE ns.user_id = p_user_id;
  v_lead := COALESCE(v_lead, 0);
  v_slept := round(v_asleep / 60.0, 2);
  v_target_wake := p_now + make_interval(mins => GREATEST(v_need - v_asleep, 0));
  v_earliest    := p_now + make_interval(mins => GREATEST(v_need - v_lead - v_asleep, 0));
  -- v215: never past need + 1 h or 10 h after he fell asleep (he is wrecked after 10 h), whichever comes first.
  -- Counted from the stager's onset when it is later, so a session onset logged too early cannot ring him at 05:00.
  v_blind_backstop := COALESCE(s.latest_wake_at,
                        LEAST(GREATEST(v_onset, COALESCE(v_sleep_start, v_onset)) + make_interval(mins => v_need + 60),
                              GREATEST(v_onset, COALESCE(v_sleep_start, v_onset)) + interval '10 hours',
                              GREATEST(v_night_end, v_onset + make_interval(mins => v_need))));
  v_backstop    := LEAST(v_blind_backstop, p_now + make_interval(mins => GREATEST(v_need + 45 - v_asleep, 0)));

  SELECT * INTO s5  FROM live_sleep_stage(p_user_id, p_now, 5)  z;
  SELECT * INTO s15 FROM live_sleep_stage(p_user_id, p_now, 15) z;
  v_awake_now := (v_n6 >= 4 AND v_aw6 >= v_n6 - 1)
              OR (COALESCE(s5.p_awake, 0) >= 0.35 AND COALESCE(s15.p_awake, 0) >= 0.30)
              OR (v_cut AND v_c6 >= 3 AND v_ch6 >= v_c6 - 1);

  v_stopped := EXISTS (SELECT 1 FROM bridge_logs b
                        WHERE b.user_id = p_user_id
                          AND b.category IN ('manual_wake_up','evt_alarm_stopped','smart_alarm_stopped')
                          AND b.created_at > v_onset + interval '3 hours' AND b.created_at <= p_now);

  -- light/REM must hold: the live check (now and 3 min ago) and no deep or awake minute in the last 4
  SELECT w.wake, w.wake_score, w.deep_prob, w.reason INTO sw_wake, sw_score, sw_dp, sw_reason
    FROM should_wake_now(p_user_id, p_now - interval '1 minute', p_now + interval '1 day', p_now) w;
  v_light_ok := sw_wake IS TRUE AND COALESCE(v_deep4, 0) = 0 AND COALESCE(v_aw4, 0) <= 1;

  v_stage := CASE WHEN v_awake_now THEN 'awake'
                  WHEN sw_dp IS NULL THEN 'unknown'
                  WHEN sw_dp >= 0.40 OR COALESCE(v_deep4,0) > 0 THEN 'deep'
                  ELSE 'light_rem' END;
  v_recpct := round(100 * LEAST(1.0, v_asleep::numeric / NULLIF(v_need, 0)));

  -- ---- Decision ----
  IF v_stopped THEN
    v_should := false; v_reason := 'stopped_by_you';
  ELSIF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at THEN
    v_should := true;  v_reason := 'deadline';                       -- a deadline is never cancelled
  ELSIF p_now >= v_night_end THEN
    v_should := false; v_reason := 'night_over';                     -- the night's minutes stop at 12:00; he is up
  ELSIF v_last_rt IS NULL OR v_last_rt < p_now - interval '15 minutes' THEN
    v_stage := 'unknown';                                            -- no strap samples in 15 min: there is no stage to report
    IF v_was_awake AND v_asleep >= v_need - 90 THEN
      v_should := false; v_reason := 'woke_on_own';                  -- up near his need when the strap went quiet
    ELSIF p_now >= v_blind_backstop THEN
      v_should := true;  v_reason := 'backstop_blind';               -- a dead strap or phone mid-sleep still rings
    ELSE
      v_should := false; v_reason := 'no_live_data_hold';
    END IF;
  ELSIF v_last_rt < p_now - interval '5 minutes' THEN
    v_should := false; v_reason := 'no_live_data_hold';              -- samples thinning out: decide on fresh data only
  ELSIF v_last_min IS NULL THEN
    v_should := false; v_reason := 'not_asleep_yet';                 -- data flows, the stager has not seen him fall asleep
  ELSIF v_awake_now AND v_n30 + v_c30 >= 24 AND v_aw30 + v_ch30 >= 24 AND v_asleep >= v_need - 30 THEN
    v_should := false; v_reason := 'woke_on_own';                    -- need nearly met and up for 24 of the last 30 min
  ELSIF v_awake_now AND v_n60 + v_c60 >= 50 AND v_aw60 + v_ch60 >= 50 THEN
    v_should := false; v_reason := 'woke_on_own';                    -- up for the last hour: he has started his day
  ELSIF v_awake_now THEN
    v_should := false; v_reason := 'awake_hold';                     -- awake for now: never ring into it, keep the night open
  ELSIF s.latest_wake_at IS NOT NULL AND p_now >= s.latest_wake_at - interval '30 minutes' AND v_light_ok THEN
    v_should := true;  v_reason := 'deadline_light';                 -- inside the last 30 min before a deadline, take light sleep
  ELSIF p_now >= v_blind_backstop THEN
    v_should := true;  v_reason := 'latest_reached';                 -- need + 1 h or 10 h after onset: the latest, counted or not
  ELSIF v_asleep < v_need - v_lead THEN
    v_should := false; v_reason := 'need_not_met';
  ELSIF v_light_ok THEN
    v_should := true;  v_reason := 'need_met_light';
  ELSIF v_asleep >= v_need + 45 THEN
    v_should := true;  v_reason := 'backstop_reached';
  ELSIF v_asleep >= v_need + 30 AND v_stage <> 'deep' THEN
    v_should := true;  v_reason := 'window_end';
  ELSE
    v_should := false; v_reason := CASE WHEN v_stage = 'deep' THEN 'deep_hold' ELSE 'light_hold' END;
  END IF;

  session_id := s.id; should_fire := v_should; reason := v_reason;
  stage := v_stage; wake_score := sw_score; deep_prob := sw_dp;
  slept_h_so_far := v_slept; target_h := v_target;
  earliest_wake_at := v_earliest; target_wake_at := v_target_wake;
  backstop_at := v_backstop; recovery_pct := v_recpct;
  status := CASE WHEN v_should THEN 'ready' ELSE COALESCE(s.status,'asleep') END;
  RETURN NEXT;
END;$function$
;

COMMIT;
