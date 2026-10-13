-- v216: a night with missing data says so, so a review never reads a dead strap or phone as a bad night.
-- night_data: 'technical_gap' when the strap or phone stopped sending and the night was not observed,
-- 'no_sleep_found' when the data is there and holds no sleep, 'complete' otherwise. It follows the
-- coverage gate's own verdict (sleep_complete + sleep_incomplete_reason from sleep_window_quality), so it
-- needs no backfill and cannot drift. A gap night already has no sleep hours or scores; this names why.
ALTER TABLE public.health_metrics ADD COLUMN IF NOT EXISTS night_data text GENERATED ALWAYS AS (
  CASE
    WHEN sleep_complete IS TRUE THEN 'complete'
    WHEN sleep_complete IS FALSE
         AND (sleep_incomplete_reason ~ '^no sleep block found'
              OR (sleep_incomplete_reason ~ '^only [0-9]+ min of sleep found' AND sleep_incomplete_reason !~ ';'))
      THEN 'no_sleep_found'
    WHEN sleep_complete IS FALSE THEN 'technical_gap'
  END) STORED;

-- One row per night for reviews: what the data says, why it is missing, and what the alarm did.
-- The night runs 19:00 the evening before to 12:00 (Berlin), as in the coverage gate.
CREATE OR REPLACE VIEW public.night_review WITH (security_invoker = true) AS
WITH n AS (
  SELECT h.*,
         (((h.metric_date - 1)::text || ' 19:00')::timestamp AT TIME ZONE 'Europe/Berlin') AS n_start,
         ((h.metric_date::text || ' 12:00')::timestamp AT TIME ZONE 'Europe/Berlin') AS n_end
    FROM public.health_metrics h
)
SELECT n.user_id,
       n.metric_date                 AS night,
       n.night_data,
       n.sleep_hours,
       n.sleep_coverage_pct          AS coverage_pct,
       n.sleep_incomplete_reason     AS gap_detail,
       CASE WHEN n.night_data = 'technical_gap' THEN COALESCE(g.causes, 'not logged') END AS gap_cause,
       CASE WHEN n.night_data = 'technical_gap' THEN g.gap_min END AS gap_min,  -- outages a later strap sync filled are not always marked recovered; only a gap night's figure is real
       w.status                      AS alarm_status,
       w.fired_at                    AS alarm_at,
       w.fired_reason                AS alarm_reason,
       w.fired_stage                 AS alarm_stage,
       t.tap_at                      AS awake_tap_at
  FROM n
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT o.cause, ', ') AS causes,
           round(sum(EXTRACT(epoch FROM LEAST(o.ended_at, n.n_end) - GREATEST(o.started_at, n.n_start)) / 60))::int AS gap_min
      FROM public.strap_outages o
     WHERE o.user_id = n.user_id AND o.started_at < n.n_end AND o.ended_at > n.n_start
       AND o.minutes > COALESCE(o.recovered_min, 0)
  ) g ON true
  LEFT JOIN LATERAL (
    SELECT s.status, s.fired_at, s.fired_reason, s.fired_stage
      FROM public.smart_wake_sessions s
     WHERE s.user_id = n.user_id AND s.armed_at >= n.n_start - interval '8 hours' AND s.armed_at < n.n_end - interval '6 hours'
     ORDER BY s.armed_at DESC LIMIT 1
  ) w ON true
  LEFT JOIN LATERAL (
    SELECT min(b.created_at) AS tap_at
      FROM public.bridge_logs b
     WHERE b.user_id = n.user_id AND b.created_at > n.n_start + interval '8 hours' AND b.created_at < n.n_end
       AND b.category IN ('manual_wake_up', 'evt_alarm_stopped', 'smart_alarm_stopped')
  ) t ON true;
