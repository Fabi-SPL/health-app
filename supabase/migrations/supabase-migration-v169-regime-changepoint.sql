-- v169 — real changepoint detection for "my baseline actually shifted".
--
-- Rolling averages can't distinguish a genuine regime shift from drift plus
-- noise, and every "vs your 28d average" comparison quietly assumes the
-- baseline is one stationary thing. The n-of-1 methods literature prescribes
-- PELT for retrospective segmentation of a personal series (exact, linear-time,
-- penalty-pruned) and an online detector for live alerting. This implements
-- PELT with a normal mean+variance cost and a BIC penalty, run nightly — on
-- daily-resolution data a nightly offline pass alerts at most one day later
-- than true online BOCPD, without needing a gamma function in plpgsql.

create table if not exists public.regime_changes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  metric text not null,
  change_date date not null,
  before_mean numeric,
  after_mean numeric,
  direction text,                  -- 'up' | 'down'
  segment_days int,                -- length of the new segment so far
  detected_at timestamptz default now(),
  unique (user_id, metric, change_date)
);
alter table public.regime_changes enable row level security;
drop policy if exists "own regime changes" on public.regime_changes;
create policy "own regime changes" on public.regime_changes
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create or replace function public.detect_regime_changes(
  p_user_id uuid,
  p_metric text,                   -- column in health_metrics
  p_days int default 365
) returns int
language plpgsql
security definer
as $$
DECLARE
  vals numeric[]; dates date[];
  n int; i int; t int; s int;
  psum numeric[]; psq numeric[];               -- prefix sums for O(1) segment cost
  f numeric[];                                  -- optimal cost up to t
  cp int[];                                     -- last changepoint before t
  cand int[]; new_cand int[];                   -- PELT pruning set
  best numeric; best_s int; c numeric; pen numeric;
  seg_n int; seg_mean numeric; seg_var numeric;
  bounds int[] := '{}'; k int;
  b_mean numeric; a_mean numeric; ins int := 0;
BEGIN
  EXECUTE format(
    'SELECT array_agg(%I ORDER BY metric_date), array_agg(metric_date ORDER BY metric_date)
       FROM health_metrics
      WHERE user_id = $1 AND metric_date >= current_date - $2
        AND %I IS NOT NULL AND %I > 0 AND COALESCE(excluded,false) = false',
    p_metric, p_metric, p_metric)
  INTO vals, dates USING p_user_id, p_days;

  n := coalesce(array_length(vals,1),0);
  IF n < 28 THEN RETURN 0; END IF;

  psum := array_fill(0::numeric, array[n+1]);
  psq  := array_fill(0::numeric, array[n+1]);
  FOR i IN 1..n LOOP
    psum[i+1] := psum[i] + vals[i];
    psq[i+1]  := psq[i] + vals[i]*vals[i];
  END LOOP;

  -- BIC-style penalty: 3 params (mean, variance, location) per extra segment.
  pen := 3 * ln(n);

  f := array_fill(0::numeric, array[n+1]);
  cp := array_fill(0, array[n+1]);
  f[1] := -pen;                                 -- so the first segment pays no penalty
  cand := array[0];

  FOR t IN 1..n LOOP
    best := NULL; best_s := 0;
    FOREACH s IN ARRAY cand LOOP
      seg_n := t - s;
      IF seg_n < 7 THEN CONTINUE; END IF;       -- min segment: a week, not a blip
      seg_mean := (psum[t+1] - psum[s+1]) / seg_n;
      seg_var  := GREATEST((psq[t+1] - psq[s+1]) / seg_n - seg_mean*seg_mean, 1e-6);
      c := f[s+1] + seg_n * ln(seg_var) + pen;
      IF best IS NULL OR c < best THEN best := c; best_s := s; END IF;
    END LOOP;
    IF best IS NULL THEN                        -- no admissible split yet
      seg_mean := psum[t+1] / t;
      seg_var := GREATEST(psq[t+1]/t - seg_mean*seg_mean, 1e-6);
      best := t * ln(seg_var); best_s := 0;
    END IF;
    f[t+1] := best; cp[t+1] := best_s;

    -- PELT pruning: a candidate whose cost already exceeds the optimum + pen
    -- can never win again.
    new_cand := array[t];
    FOREACH s IN ARRAY cand LOOP
      seg_n := t - s;
      IF seg_n < 7 THEN new_cand := new_cand || s; CONTINUE; END IF;
      seg_mean := (psum[t+1] - psum[s+1]) / seg_n;
      seg_var  := GREATEST((psq[t+1] - psq[s+1]) / seg_n - seg_mean*seg_mean, 1e-6);
      IF f[s+1] + seg_n * ln(seg_var) <= f[t+1] THEN new_cand := new_cand || s; END IF;
    END LOOP;
    cand := new_cand;
  END LOOP;

  -- Walk back the optimal segmentation.
  t := n;
  WHILE t > 0 LOOP
    s := cp[t+1];
    IF s > 0 THEN bounds := s || bounds; END IF;
    t := s;
  END LOOP;

  FOREACH k IN ARRAY bounds LOOP
    b_mean := (psum[k+1] - psum[GREATEST(k-27,0)+1]) / (k - GREATEST(k-27,0));
    a_mean := (psum[LEAST(k+28,n)+1] - psum[k+1]) / (LEAST(k+28,n) - k);
    INSERT INTO regime_changes (user_id, metric, change_date, before_mean, after_mean, direction, segment_days)
    VALUES (p_user_id, p_metric, dates[k+1],
            round(b_mean,2), round(a_mean,2),
            CASE WHEN a_mean > b_mean THEN 'up' ELSE 'down' END,
            n - k)
    ON CONFLICT (user_id, metric, change_date) DO UPDATE
      SET after_mean = excluded.after_mean, segment_days = excluded.segment_days;
    ins := ins + 1;
  END LOOP;

  RETURN ins;
END;
$$;

-- Nightly sweep over the metrics whose baseline shifting actually matters.
create or replace function public.regime_detect_nightly()
returns void
language plpgsql
security definer
as $$
DECLARE u uuid := '372210e5-1dda-41b3-b759-5ff72293b8ff'; m text;
BEGIN
  FOREACH m IN ARRAY array['hrv_avg','resting_hr','sleep_hours','respiratory_rate','skin_temp'] LOOP
    PERFORM public.detect_regime_changes(u, m, 365);
  END LOOP;
END;
$$;

select cron.schedule('regime-detect-nightly', '50 5 * * *', $$select public.regime_detect_nightly()$$);
