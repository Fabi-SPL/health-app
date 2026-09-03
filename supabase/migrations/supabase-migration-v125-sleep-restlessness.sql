-- migration v125_sleep_restlessness.sql
-- Honest sleep-quality detail from realtime HR/HRV (single-user, bespoke).
--
-- WHY NOT "sleep architecture / REM staging":
--   * The realtime_health.sleep_stage labels are the broken on-device classifier:
--     on a good night it flips so fast that DISTINCT-minute stage counts exceed the
--     in-bed window (12h of "stages" in an 8.5h night); on the drunk night it labels
--     the entire high-HR sleep as "awake". Unusable for staging.
--   * health_metrics.rem_sleep_min is NOT measured REM, it is a fixed ~26% of sleep
--     (Jun8 134/509, Jun1 140/533, Jun4 138/533, Jun9 131/517 = all 26%). A textbook
--     constant, so there is no ground truth to validate a REM detector against.
--   => Reporting "you got 134 min REM" would be authoritative-looking fiction.
--      So we DROP the REM/deep/light labels entirely and surface only what is real.
--
-- WHAT IS REAL (measured, not inferred):
--   * restless_min / wakeups = minutes where HR spikes > sleeping_baseline + 18 bpm,
--     and the count of distinct spike stretches. A measured HR jump is a fact.
--   * sleeping_hr = median overnight HR (captures e.g. the drunk night at 66 vs the
--     normal ~55, a true booze signal).
--   * stability 0-10 = derived from those measured arousals (+ a light penalty for
--     sustained autonomic swing). Penalises real restlessness, not a guessed stage.
--
-- WHAT IS LABELED-ESTIMATE (kept, but never presented as truth):
--   * unsettled_min / dream_periods_est = minutes of high minute-to-minute HRV swing
--     (the documented autonomic-instability signature of REM-like sleep) with HR below
--     wake level. Plausible range (60-150/night) and directionally sane (lowest on the
--     drunk night, matching alcohol's known REM suppression) but UNVALIDATED on this
--     strap. The note string says so out loud.
--
-- Validated 5 nights: normal Jun9 = stability 8 (best, fewest restless); rec72 Jun1
-- = stability 1 (22 restless / 6 wakeups); drunk Jun10 = sleeping_hr 66 + lowest dream
-- estimate (alcohol suppresses REM). Applied live via /pg/query (DB is source of truth).
--
-- Supersedes the abandoned sleep_architecture(uuid,date), which is DROPped here.

CREATE OR REPLACE FUNCTION public.sleep_restlessness(p_user_id uuid, p_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE d date; s_start timestamptz; s_end timestamptz; sleep_hr numeric;
  restless_min int; arousals int; unsettled_min int; unsettled_periods int; total_min int; stability int; note text;
BEGIN
  IF p_date IS NULL THEN SELECT max(metric_date) INTO d FROM health_metrics WHERE user_id=p_user_id AND sleep_hours>0; ELSE d:=p_date; END IF;
  SELECT sleep_start, sleep_end INTO s_start, s_end FROM health_metrics WHERE user_id=p_user_id AND metric_date=d;
  IF s_start IS NULL OR s_end IS NULL THEN RETURN jsonb_build_object('error','no sleep window for '||d); END IF;
  WITH pm AS (
    SELECT date_trunc('minute',recorded_at) m, avg(heart_rate) hr,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_rmssd) FILTER (WHERE hrv_rmssd>0) mh
    FROM realtime_health WHERE user_id=p_user_id AND recorded_at BETWEEN s_start AND s_end AND heart_rate>0 GROUP BY 1),
  base AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY hr) shr FROM pm),
  roll AS (SELECT pm.m, pm.hr, pm.mh, b.shr,
      stddev(pm.mh) OVER (ORDER BY pm.m ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) sw
    FROM pm CROSS JOIN base b),
  tagged AS (SELECT m, hr, shr,
      (hr > shr + 18) is_restless,
      (sw > 9 AND hr < shr + 13) is_unsettled
    FROM roll),
  ar AS (SELECT m, row_number() OVER (ORDER BY m) rn FROM tagged WHERE is_restless),
  un AS (SELECT m, row_number() OVER (ORDER BY m) rn FROM tagged WHERE is_unsettled)
  SELECT COALESCE((SELECT round(shr) FROM base),60),
    count(*) FILTER (WHERE is_restless), count(*) FILTER (WHERE is_unsettled), count(*),
    COALESCE((SELECT count(DISTINCT (m - (rn||' min')::interval)) FROM ar),0),
    COALESCE((SELECT count(DISTINCT (m - (rn||' min')::interval)) FROM un),0)
    INTO sleep_hr, restless_min, unsettled_min, total_min, arousals, unsettled_periods FROM tagged;
  stability := GREATEST(0, 10 - LEAST(10, round(restless_min/3.0) + round(unsettled_min/90.0)));
  note := format('Slept ~%sh. %s restless mins (%s wake-ups), autonomic stability %s/10. ~%s unsettled/dream-like mins across %s stretches. (Measured arousals are real; dream estimate is HRV-based, not ground-truth.)',
    round(total_min/60.0,1), restless_min, arousals, stability, unsettled_min, unsettled_periods);
  RETURN jsonb_build_object('date',d,'in_bed_h',round(total_min/60.0,1),'sleeping_hr',sleep_hr,
    'restless_min',restless_min,'wakeups',arousals,'stability',stability,
    'unsettled_min',unsettled_min,'dream_periods_est',unsettled_periods,'window_min',total_min,'note',note);
END;$f$;

COMMENT ON FUNCTION public.sleep_restlessness IS 'v125: honest sleep-quality from realtime HR/HRV. restless_min/wakeups = MEASURED HR spikes (real). unsettled/dream = HRV-swing estimate, NOT validated (this strap has no ground-truth REM; health_metrics rem is a 26% constant). Replaces the abandoned sleep_architecture which leaned on the broken sleep_stage labels.';

DROP FUNCTION IF EXISTS public.sleep_architecture(uuid, date);
