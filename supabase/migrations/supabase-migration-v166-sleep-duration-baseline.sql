-- v166 — a personal sleep-duration baseline, so the client can score deviation
-- from HIS own average instead of absolute hour thresholds.
--
-- Why: the only within-person validated predictor of next-day cognition in the
-- literature is sleep DURATION measured as a deviation from the person's own
-- average (+0.11 processing-speed units per extra hour, 95% CI 0.06-0.15,
-- 21-day intensive longitudinal design, N=326, Oxford Sleep 2026). The
-- between-person effect was null. Absolute cutoffs like ">= 7h is good" are a
-- between-person construct and carry no within-person signal.
--
-- Sleep EFFICIENCY was null in the same study (0.00, CI -0.01 to 0.01), so it
-- must not feed a cognitive score at all.
--
-- Excluded nights are dropped: a night the auto-excluder already flagged as
-- broken would drag the mean down and make every normal night look long.

create or replace function public.sleep_duration_baseline(
  p_user_id uuid,
  p_days int default 30
) returns table (
  mean_hours numeric,
  sd_hours numeric,
  n_nights int
)
language sql
stable
security invoker
as $$
  select
    round(avg(sleep_hours)::numeric, 2)                      as mean_hours,
    round(coalesce(stddev_samp(sleep_hours), 0)::numeric, 2) as sd_hours,
    count(*)::int                                            as n_nights
  from public.health_metrics
  where user_id = p_user_id
    and metric_date >= (current_date at time zone 'Europe/Berlin')::date - p_days
    and metric_date <  (current_date at time zone 'Europe/Berlin')::date
    and sleep_hours is not null
    and sleep_hours > 0
    and coalesce(excluded, false) = false;
$$;

grant execute on function public.sleep_duration_baseline(uuid, int) to authenticated;
