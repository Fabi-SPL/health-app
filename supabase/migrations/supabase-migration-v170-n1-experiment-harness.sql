-- v170 — the n=1 self-experiment harness.
--
-- The point of having physiology and task-completion in one Postgres: claims
-- about HIS body get tested on HIS data instead of imported from group
-- studies. Two instruments:
--
-- 1. n1_experiments / n1_phases + an Edgington AB randomization test — the one
--    method that produces a real p-value from a single subject. For deliberate
--    interventions (supplement, bedtime, caffeine cutoff). Design constraints
--    from the SCED power literature are enforced, not advisory: >=15 obs per
--    phase minimum (30 is where power actually arrives), because
--    autocorrelation degrades power monotonically.
--
-- 2. n1_within_person_assoc — a circular-shift permutation test for
--    observational within-person association (e.g. "does MY daily RMSSD track
--    MY daily task throughput"). Circular shifts preserve each series' own
--    autocorrelation, which naive day-shuffling destroys — naive shuffling is
--    exactly how self-trackers manufacture fake significance.

create table if not exists public.n1_experiments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  name text not null,
  hypothesis text not null,
  outcome_metric text not null,          -- health_metrics column
  status text not null default 'design', -- design | running | analyzed | abandoned
  result jsonb,
  created_at timestamptz default now()
);
create table if not exists public.n1_phases (
  id uuid primary key default gen_random_uuid(),
  experiment_id uuid not null references public.n1_experiments(id) on delete cascade,
  phase text not null,                   -- 'baseline' | 'intervention'
  start_date date not null,
  end_date date
);
alter table public.n1_experiments enable row level security;
alter table public.n1_phases enable row level security;
drop policy if exists "own experiments" on public.n1_experiments;
create policy "own experiments" on public.n1_experiments
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "own phases" on public.n1_phases;
create policy "own phases" on public.n1_phases
  for all using (exists (select 1 from public.n1_experiments e
                          where e.id = experiment_id and e.user_id = auth.uid()));

-- Edgington AB randomization test: was the outcome different after the
-- intervention started, compared against every other place the start could
-- have fallen? p = rank of the observed |mean diff| among all pseudo-starts.
create or replace function public.n1_ab_randomization_test(
  p_user_id uuid,
  p_metric text,
  p_intervention_start date,
  p_window_start date,
  p_window_end date default current_date,
  p_min_phase int default 15
) returns jsonb
language plpgsql
security definer
as $$
DECLARE
  vals numeric[]; dates date[]; n int; i int;
  obs_idx int := 0; obs_stat numeric; stat numeric;
  n_starts int := 0; n_extreme int := 0;
  b_mean numeric; a_mean numeric;
BEGIN
  EXECUTE format(
    'SELECT array_agg(%I ORDER BY metric_date), array_agg(metric_date ORDER BY metric_date)
       FROM health_metrics
      WHERE user_id=$1 AND metric_date BETWEEN $2 AND $3
        AND %I IS NOT NULL AND %I > 0 AND COALESCE(excluded,false)=false',
    p_metric, p_metric, p_metric)
  INTO vals, dates USING p_user_id, p_window_start, p_window_end;

  n := coalesce(array_length(vals,1),0);
  IF n < 2*p_min_phase THEN
    RETURN jsonb_build_object('error',
      format('only %s usable days — need >= %s (%s per phase). 30/phase is where power actually arrives.',
             n, 2*p_min_phase, p_min_phase));
  END IF;

  FOR i IN 1..n LOOP
    IF dates[i] >= p_intervention_start AND obs_idx = 0 THEN obs_idx := i; END IF;
  END LOOP;
  IF obs_idx < p_min_phase + 1 OR obs_idx > n - p_min_phase + 1 THEN
    RETURN jsonb_build_object('error','intervention start leaves a phase shorter than the minimum');
  END IF;

  SELECT avg(v) FILTER (WHERE ord >= obs_idx) - avg(v) FILTER (WHERE ord < obs_idx)
    INTO obs_stat FROM unnest(vals) WITH ORDINALITY t(v, ord);

  FOR i IN (p_min_phase+1)..(n-p_min_phase+1) LOOP
    SELECT avg(v) FILTER (WHERE ord >= i) - avg(v) FILTER (WHERE ord < i)
      INTO stat FROM unnest(vals) WITH ORDINALITY t(v, ord);
    n_starts := n_starts + 1;
    IF abs(stat) >= abs(obs_stat) THEN n_extreme := n_extreme + 1; END IF;
  END LOOP;

  SELECT avg(v) FILTER (WHERE ord < obs_idx), avg(v) FILTER (WHERE ord >= obs_idx)
    INTO b_mean, a_mean FROM unnest(vals) WITH ORDINALITY t(v, ord);

  RETURN jsonb_build_object(
    'n_days', n,
    'baseline_days', obs_idx - 1,
    'intervention_days', n - obs_idx + 1,
    'baseline_mean', round(b_mean, 2),
    'intervention_mean', round(a_mean, 2),
    'effect', round(obs_stat, 2),
    'p_value', round(n_extreme::numeric / n_starts, 4),
    'method', 'Edgington AB randomization over ' || n_starts || ' admissible start points',
    'caveat', 'observational unless the start date was randomized in advance');
END;
$$;

-- Within-person association with circular-shift permutation. Tests whether two
-- daily series move together IN HIM, preserving both series' autocorrelation.
create or replace function public.n1_within_person_assoc(
  p_user_id uuid,
  p_x_metric text,                       -- health_metrics column, e.g. hrv_avg
  p_days int default 365,
  p_shifts int default 500
) returns jsonb
language plpgsql
security definer
as $$
DECLARE
  xs numeric[]; ys numeric[]; n int; i int; k int;
  obs_r numeric; r numeric; n_extreme int := 0;
BEGIN
  -- x = the overnight metric; y = that day's completed-task throughput.
  EXECUTE format(
    'WITH days AS (
       SELECT h.metric_date d, h.%I x,
              (SELECT count(*) FROM tasks t
                WHERE t.user_id=h.user_id AND t.completed_at::date=h.metric_date) y
         FROM health_metrics h
        WHERE h.user_id=$1 AND h.metric_date >= current_date - $2
          AND h.%I IS NOT NULL AND h.%I > 0 AND COALESCE(h.excluded,false)=false)
     SELECT array_agg(x ORDER BY d), array_agg(y ORDER BY d) FROM days WHERE y > 0',
    p_x_metric, p_x_metric, p_x_metric)
  INTO xs, ys USING p_user_id, p_days;

  n := coalesce(array_length(xs,1),0);
  IF n < 30 THEN
    RETURN jsonb_build_object('error', format('only %s days with both signals — need >= 30', n));
  END IF;

  SELECT corr(x,y) INTO obs_r FROM unnest(xs,ys) t(x,y);
  IF obs_r IS NULL THEN RETURN jsonb_build_object('error','zero variance'); END IF;

  FOR i IN 1..p_shifts LOOP
    k := 1 + floor(random() * (n-1))::int;   -- circular offset, never 0
    SELECT corr(x, y) INTO r
      FROM (SELECT xs[ord] x, ys[1 + ((ord - 1 + k) % n)] y
              FROM generate_series(1,n) ord) t;
    IF abs(r) >= abs(obs_r) THEN n_extreme := n_extreme + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'n_days', n,
    'r', round(obs_r, 3),
    'p_value', round((n_extreme + 1)::numeric / (p_shifts + 1), 4),
    'method', p_shifts || ' circular-shift permutations (autocorrelation-preserving)',
    'read', CASE WHEN (n_extreme + 1)::numeric / (p_shifts + 1) < 0.05
                 THEN 'within-person association present'
                 ELSE 'no within-person evidence — treat the claim as untested, not true' END);
END;
$$;
