-- v168 — permutation-tested, FDR-controlled food correlations.
--
-- compute_food_correlations ran 5 features x 4 outcomes = 20 comparisons with
-- no significance testing at all; "confidence" was occurrences/20, which is a
-- sample-size label wearing a statistics costume. With this many mutually
-- correlated variables, chance alone guarantees impressive-looking deltas —
-- the classic self-tracker false-discovery machine.
--
-- Fix, per the n-of-1 methods literature: a permutation test per comparison
-- (shuffle which days carry the feature label, 200 draws, p = fraction of
-- draws with |mean diff| >= observed), then Benjamini-Hochberg across the
-- whole batch. BH on permutation p-values is the prescribed approach when
-- tests are correlated. A row only lands in food_correlations if at least one
-- of its outcomes survives FDR at q = 0.10.

alter table public.food_correlations
  add column if not exists p_values jsonb,
  add column if not exists fdr_pass boolean default false;

-- BH step-up: given p-values, return pass flags at rate q.
create or replace function public.fdr_bh_pass(p_pvals numeric[], p_q numeric default 0.10)
returns boolean[]
language plpgsql
immutable
as $$
DECLARE
  m int := coalesce(array_length(p_pvals,1),0);
  idx int[]; sorted numeric[]; cutoff numeric := 0; i int;
  pass boolean[] := '{}';
BEGIN
  IF m = 0 THEN RETURN pass; END IF;
  SELECT array_agg(p order by p), array_agg(ord order by p)
    INTO sorted, idx
    FROM unnest(p_pvals) WITH ORDINALITY t(p, ord);
  -- largest k with p(k) <= q*k/m; every p <= p(k) passes
  FOR i IN 1..m LOOP
    IF sorted[i] <= p_q * i / m THEN cutoff := sorted[i]; END IF;
  END LOOP;
  FOR i IN 1..m LOOP
    pass := pass || (p_pvals[i] <= cutoff AND cutoff > 0);
  END LOOP;
  RETURN pass;
END;
$$;

create or replace function public.compute_food_correlations(p_user_id uuid, p_window_days integer default 60)
returns integer
language plpgsql
security definer
as $$
DECLARE
  baseline_hrv numeric; baseline_rhr numeric; baseline_rec numeric; baseline_sleep numeric;
  inserted_count int := 0;
  feat record; oc text; perm int;
  flags boolean[]; vals numeric[]; n_days int; n_flag int;
  obs_diff numeric; extreme int; shuffled boolean[];
  all_p numeric[] := '{}'; all_keys text[] := '{}';
  pass boolean[]; pv jsonb; any_pass boolean; key_i int;
  OUTCOMES constant text[] := array['hrv','rhr','rec','slp'];
BEGIN
  SELECT
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_avg) FILTER (WHERE hrv_avg > 0),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY resting_hr) FILTER (WHERE resting_hr > 0),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY recovery_score) FILTER (WHERE recovery_score > 0),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY sleep_hours * 60) FILTER (WHERE sleep_hours > 0)
  INTO baseline_hrv, baseline_rhr, baseline_rec, baseline_sleep
  FROM health_metrics
  WHERE user_id = p_user_id AND metric_date >= current_date - p_window_days;

  IF baseline_hrv IS NULL OR baseline_hrv = 0 THEN RETURN 0; END IF;

  -- Day-level rollup, next-night outcomes attached.
  CREATE TEMP TABLE IF NOT EXISTS _fc_days (
    day date, daily_nova numeric, daily_mind numeric, daily_kcal numeric,
    last_meal_min numeric, hrv numeric, rhr numeric, rec numeric, slp numeric
  ) ON COMMIT DROP;
  TRUNCATE _fc_days;

  INSERT INTO _fc_days
  SELECT df.day, df.daily_nova, df.daily_mind, df.daily_kcal, df.last_meal_min,
         h.hrv_avg, h.resting_hr, h.recovery_score, (COALESCE(h.sleep_hours,0)*60)::numeric
  FROM (
    SELECT captured_at::date AS day,
      AVG(nova_avg)  FILTER (WHERE nova_avg IS NOT NULL)  AS daily_nova,
      AVG(mind_score) FILTER (WHERE mind_score IS NOT NULL) AS daily_mind,
      SUM(total_kcal) FILTER (WHERE total_kcal IS NOT NULL) AS daily_kcal,
      MAX(EXTRACT(hour FROM captured_at)*60 + EXTRACT(minute FROM captured_at)) AS last_meal_min
    FROM food_entries
    WHERE user_id = p_user_id
      AND captured_at >= now() - (p_window_days || ' days')::interval
    GROUP BY 1
  ) df
  LEFT JOIN health_metrics h
    ON h.user_id = p_user_id AND h.metric_date = (df.day + interval '1 day')::date
  WHERE h.hrv_avg > 0;

  SELECT count(*) INTO n_days FROM _fc_days;
  IF n_days < 14 THEN RETURN 0; END IF;

  -- Pass 1: permutation p-value for every (feature, outcome) pair.
  FOR feat IN
    SELECT * FROM (VALUES
      ('high_nova',  'NOVA >= 3.5',       'daily_nova >= 3.5'),
      ('low_nova',   'NOVA <= 1.5',       'daily_nova <= 1.5'),
      ('high_mind',  'mind_score >= 10',  'daily_mind >= 10'),
      ('late_eating','last meal >= 21:00','last_meal_min >= 1260'),
      ('high_kcal',  'daily_kcal > 2800', 'daily_kcal > 2800')
    ) f(feature, bucket, cond)
  LOOP
    EXECUTE format('SELECT array_agg((%s)::boolean ORDER BY day) FROM _fc_days', feat.cond) INTO flags;
    n_flag := (SELECT count(*) FROM unnest(flags) g WHERE g);
    IF n_flag < 5 OR n_flag > n_days - 5 THEN CONTINUE; END IF;

    FOREACH oc IN ARRAY OUTCOMES LOOP
      EXECUTE format('SELECT array_agg(%I ORDER BY day) FROM _fc_days', oc) INTO vals;
      SELECT avg(v) FILTER (WHERE f) - avg(v) FILTER (WHERE NOT f)
        INTO obs_diff
        FROM unnest(vals, flags) t(v, f) WHERE v IS NOT NULL;
      IF obs_diff IS NULL THEN
        all_p := all_p || 1.0::numeric;
        all_keys := all_keys || (feat.feature || ':' || oc);
        CONTINUE;
      END IF;

      extreme := 0;
      FOR perm IN 1..200 LOOP
        SELECT array_agg(f ORDER BY random()) INTO shuffled FROM unnest(flags) t(f);
        IF abs((SELECT avg(v) FILTER (WHERE f) - avg(v) FILTER (WHERE NOT f)
                FROM unnest(vals, shuffled) t(v, f) WHERE v IS NOT NULL)) >= abs(obs_diff) THEN
          extreme := extreme + 1;
        END IF;
      END LOOP;
      -- +1/+1 keeps p off zero — a permutation p of 0 overstates certainty
      all_p := all_p || ((extreme + 1)::numeric / 201);
      all_keys := all_keys || (feat.feature || ':' || oc);
    END LOOP;
  END LOOP;

  IF array_length(all_p,1) IS NULL THEN RETURN 0; END IF;
  pass := public.fdr_bh_pass(all_p, 0.10);

  -- Pass 2: insert only features with at least one FDR-surviving outcome.
  FOR feat IN
    SELECT * FROM (VALUES
      ('high_nova',  'NOVA >= 3.5',       'daily_nova >= 3.5'),
      ('low_nova',   'NOVA <= 1.5',       'daily_nova <= 1.5'),
      ('high_mind',  'mind_score >= 10',  'daily_mind >= 10'),
      ('late_eating','last meal >= 21:00','last_meal_min >= 1260'),
      ('high_kcal',  'daily_kcal > 2800', 'daily_kcal > 2800')
    ) f(feature, bucket, cond)
  LOOP
    pv := '{}'::jsonb; any_pass := false;
    FOREACH oc IN ARRAY OUTCOMES LOOP
      key_i := array_position(all_keys, feat.feature || ':' || oc);
      IF key_i IS NOT NULL THEN
        pv := pv || jsonb_build_object(oc, round(all_p[key_i], 4));
        IF pass[key_i] THEN any_pass := true; END IF;
      END IF;
    END LOOP;
    IF NOT any_pass THEN CONTINUE; END IF;

    EXECUTE format($ins$
      INSERT INTO food_correlations (
        user_id, feature, bucket, occurrences,
        hrv_delta_pct, rhr_delta_bpm, recovery_delta_pct, sleep_delta_min,
        confidence, window_days, p_values, fdr_pass)
      SELECT %L, %L, %L, count(*),
        round(((avg(hrv) FILTER (WHERE %s) - %L::numeric)/%L::numeric*100)::numeric, 2),
        round((avg(rhr) FILTER (WHERE %s) - %L::numeric)::numeric, 1),
        round(((avg(rec) FILTER (WHERE %s) - %L::numeric)/NULLIF(%L::numeric,0)*100)::numeric, 2),
        round((avg(slp) FILTER (WHERE %s) - %L::numeric)::numeric, 1),
        LEAST(0.95, (count(*) FILTER (WHERE %s))::numeric/20)::numeric(3,2),
        %s, %L::jsonb, true
      FROM _fc_days WHERE (%s)
    $ins$, p_user_id, feat.feature, feat.bucket,
           feat.cond, baseline_hrv, baseline_hrv,
           feat.cond, baseline_rhr,
           feat.cond, baseline_rec, baseline_rec,
           feat.cond, baseline_sleep,
           feat.cond, p_window_days, pv::text, feat.cond);
    inserted_count := inserted_count + 1;
  END LOOP;

  RETURN inserted_count;
END;
$$;
