-- v200: recompute a night when its strap history arrives late.
-- The 05:00 job recomputes only yesterday. A night that backfills days later (app killed, history
-- wedged, v115 unwedge) kept the partial score it got on the morning, e.g. 10-08: 22:33-00:01, 1h28m.

CREATE TABLE IF NOT EXISTS public.night_backfill_marks (
  user_id uuid NOT NULL,
  metric_date date NOT NULL,
  backfill_rows integer NOT NULL DEFAULT 0,
  recomputed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, metric_date)
);
ALTER TABLE public.night_backfill_marks ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.recompute_backfilled_nights(p_user_id uuid, p_days integer DEFAULT 14)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  d date; n_rows int; n_recent int; prev int; done int := 0;
  w_from timestamptz; w_to timestamptz; msg text;
BEGIN
  FOR d IN SELECT generate_series(((now() AT TIME ZONE 'Europe/Berlin')::date - p_days),
                                  (now() AT TIME ZONE 'Europe/Berlin')::date, interval '1 day')::date
  LOOP
    -- the night that ends on d: 18:00 the evening before to 14:00 that day, Berlin time
    w_from := ((d - 1)::timestamp + interval '18 hours') AT TIME ZONE 'Europe/Berlin';
    w_to   := (d::timestamp + interval '14 hours') AT TIME ZONE 'Europe/Berlin';
    SELECT count(*), count(*) FILTER (WHERE created_at > now() - interval '10 minutes')
      INTO n_rows, n_recent
      FROM realtime_health
     WHERE user_id = p_user_id AND source IN ('whoop_ble_backfill', 'whoop_ble_history')
       AND recorded_at >= w_from AND recorded_at < w_to;
    CONTINUE WHEN n_rows = 0 OR n_recent > 0;   -- nothing late, or still downloading
    SELECT backfill_rows INTO prev FROM night_backfill_marks WHERE user_id = p_user_id AND metric_date = d;
    CONTINUE WHEN prev IS NOT NULL AND n_rows < prev + 60;   -- under a minute or so of new data
    PERFORM recompute_health_metrics(p_user_id, d);
    INSERT INTO night_backfill_marks (user_id, metric_date, backfill_rows, recomputed_at)
    VALUES (p_user_id, d, n_rows, now())
    ON CONFLICT (user_id, metric_date) DO UPDATE SET backfill_rows = EXCLUDED.backfill_rows, recomputed_at = now();
    msg := 'date=' || d || ' backfill_rows=' || n_rows || ' prev=' || COALESCE(prev, 0);
    INSERT INTO bridge_logs (user_id, source, category, key, value, content)
    VALUES (p_user_id, 'server', 'night_backfill_recompute', 'night_backfill_recompute', msg,
            '[SERVER] night_backfill_recompute: ' || msg);
    done := done + 1;
  END LOOP;
  RETURN done;
END;
$function$;

SELECT cron.schedule('recompute_backfilled_nights', '7,27,47 * * * *',
  $$SELECT public.recompute_backfilled_nights('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)$$);
