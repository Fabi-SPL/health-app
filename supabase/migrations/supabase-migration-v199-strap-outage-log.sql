-- v199: strap outage log. Every silence of the live strap stream of 10+ minutes gets a row in
-- strap_outages with a cause, classified from what the app itself reported around it: the 2-minute
-- console heartbeat (status, HR, strap battery, process uptime), BLE connect/disconnect events,
-- crash reports the app uploads on its next launch, and strap charging/firmware-crash events.
--   app_crashed           the app reported a crash whose time falls at the start of the silence
--   app_killed            no heartbeat during the silence and a fresh process afterwards: iOS ended it
--   app_suspended         same process before and after, but iOS gave it no time to run
--   app_silent            ongoing, nothing from the app at all (killed, phone off or offline)
--   history_blocking_live heartbeats say "Syncing history": live HR is off until the download ends
--   ble_disconnected      heartbeats say "Connecting": the Bluetooth link was down
--   strap_battery_empty   disconnected with the strap at <= 3 %
--   no_heart_rate         connected, but the strap sent HR 0 (off the wrist / sensor not measuring)
--   upload_failed         the app had HR but rows never reached the server
-- refresh_strap_outages() runs every 5 minutes; strap_outage_latest() is what the app asks on reconnect.
-- Rollback: supabase-migration-v199-rollback.sql

CREATE INDEX IF NOT EXISTS idx_knowledge_entries_device_log_time
  ON public.knowledge_entries (user_id, created_at) WHERE category = 'device_log';

CREATE TABLE IF NOT EXISTS public.strap_outages (
  user_id uuid NOT NULL,
  started_at timestamptz NOT NULL,
  ended_at timestamptz,
  minutes integer NOT NULL,
  cause text NOT NULL,
  detail text,
  evidence jsonb,
  recovered_min integer NOT NULL DEFAULT 0,
  night boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, started_at)
);
ALTER TABLE public.strap_outages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS strap_outages_select ON public.strap_outages;
CREATE POLICY strap_outages_select ON public.strap_outages FOR SELECT USING (auth.uid() = user_id);

CREATE OR REPLACE FUNCTION public.app_heartbeats(p_user_id uuid, p_from timestamptz, p_to timestamptz)
 RETURNS TABLE(at timestamptz, status text, hr integer, strap_bat integer, asleep boolean,
               up_min integer, phone_bat integer, mem_mb integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT k.created_at,
         substring(l from 'Heartbeat: (.*?) HR='),
         substring(l from ' HR=([0-9]+)')::int,
         substring(l from ' bat=([0-9]+)%')::int,
         substring(l from ' sleep=([a-z]+)') = 'true',
         COALESCE(substring(l from 'up=([0-9]+)d')::int, 0) * 1440
           + COALESCE(substring(l from 'up=(?:[0-9]+d )?([0-9]+)h')::int, 0) * 60
           + COALESCE(substring(l from 'up=(?:[0-9]+d )?(?:[0-9]+h )?([0-9]+)m')::int, 0),
         substring(l from ' phone=([0-9]+)%')::int,
         substring(l from ' mem=([0-9]+)MB')::int
    FROM knowledge_entries k, jsonb_array_elements_text(k.details->'lines') l
   WHERE k.user_id = p_user_id AND k.category = 'device_log'
     AND k.created_at >= p_from AND k.created_at < p_to
     AND l LIKE '%Heartbeat:%'
$function$;

CREATE OR REPLACE FUNCTION public.classify_strap_gap(p_user_id uuid, p_from timestamptz, p_to timestamptz)
 RETURNS TABLE(cause text, detail text, evidence jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  t_end timestamptz := COALESCE(p_to, now());
  gap_min numeric := extract(epoch from (COALESCE(p_to, now()) - p_from)) / 60;
  n_hb int; n_sync int; n_conn int; n_hr0 int; n_hr int;
  hb_b record; hb_a record;
  disc_reason text; n_disc int;
  crash_line text; prev_exit text;
  chg boolean; fw_crash int;
  c text; d text; extra text := ''; alive numeric; top int;
  hm text := to_char(p_from AT TIME ZONE 'Europe/Berlin', 'HH24:MI');
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE h.status LIKE 'Syncing%'),
         count(*) FILTER (WHERE h.status LIKE 'Connecting%' OR h.status LIKE 'Scanning%'
                             OR h.status LIKE 'Disconnected%' OR h.status LIKE 'Bluetooth%'),
         count(*) FILTER (WHERE h.status IN ('Streaming', 'Connected') AND h.hr = 0),
         count(*) FILTER (WHERE h.status IN ('Streaming', 'Connected') AND h.hr > 0)
    INTO n_hb, n_sync, n_conn, n_hr0, n_hr
    FROM app_heartbeats(p_user_id, p_from + interval '3 min', t_end) h;

  SELECT * INTO hb_b FROM app_heartbeats(p_user_id, p_from - interval '30 min', p_from + interval '3 min') h
   ORDER BY h.at DESC LIMIT 1;
  IF p_to IS NOT NULL THEN
    SELECT * INTO hb_a FROM app_heartbeats(p_user_id, p_to - interval '1 min', p_to + interval '20 min') h
     ORDER BY h.at LIMIT 1;
  END IF;

  SELECT count(*), min(substring(b.value from 'reason=(.*?) code=') || ' (code ' || substring(b.value from 'code=([0-9]+)') || ')')
    INTO n_disc, disc_reason
    FROM bridge_logs b
   WHERE b.user_id = p_user_id AND b.category = 'evt_ble_disconnected'
     AND b.created_at BETWEEN p_from - interval '5 min' AND t_end;

  -- crash reports arrive on the next launch; their own at= says when the process died
  SELECT b.value INTO crash_line FROM bridge_logs b
   WHERE b.user_id = p_user_id AND b.category = 'app_crash'
     AND b.created_at >= p_from AND b.created_at < t_end + interval '2 hours'
     AND (substring(b.value from 'at=([^ ]+)')::timestamptz BETWEEN p_from - interval '3 min' AND p_from + interval '15 min'
          OR substring(b.value from 'end=([^ ]+)')::timestamptz BETWEEN p_from - interval '3 min' AND p_from + interval '15 min')
   ORDER BY b.created_at LIMIT 1;
  SELECT b.value INTO prev_exit FROM bridge_logs b
   WHERE b.user_id = p_user_id AND b.category = 'app_prev_exit'
     AND b.created_at >= p_from AND b.created_at < t_end + interval '30 min'
   ORDER BY b.created_at LIMIT 1;

  SELECT bool_or(w.event_type = 'charging_on'), count(*) FILTER (WHERE w.event_type = 'memfault_crash')
    INTO chg, fw_crash
    FROM whoop_events w
   WHERE w.user_id = p_user_id AND w.event_type IN ('charging_on', 'memfault_crash')
     AND w.recorded_at BETWEEN p_from - interval '5 min' AND t_end;

  -- a running app uploads a heartbeat every ~2 min; a handful across a long silence means it was mostly dead
  alive := n_hb / GREATEST(1, gap_min / 2);
  top := GREATEST(n_sync, n_conn, n_hr0, n_hr);
  IF n_hb > 0 AND alive < 0.25 THEN
    extra := ' The app was only alive for about ' || (n_hb * 2) || ' min of it, and then it was mostly '
             || CASE top WHEN n_sync THEN 'downloading old history (live HR off)' WHEN n_conn THEN 'reconnecting'
                         WHEN n_hr0 THEN 'connected with no heart rate' ELSE 'streaming' END || '.';
  END IF;

  IF n_hb = 0 OR alive < 0.25 THEN
    IF crash_line IS NOT NULL THEN
      c := 'app_crashed';
      d := 'LucidHealth crashed at ' || hm || ' (' || COALESCE(substring(crash_line from 'type=([^ ]+)'), 'crash')
           || '). iOS does not restart a crashed app until you open it.';
    ELSIF hb_a.up_min IS NOT NULL AND hb_a.up_min < gap_min - 5 AND n_hb = 0 THEN
      c := 'app_killed';
      d := 'The app stopped running at ' || hm || ' while ' || lower(COALESCE(hb_b.status, 'running'))
           || ' and only started again when it was reopened. No crash report reached the server, so iOS ended it'
           || ' (memory or watchdog) or it crashed before it could report.';
    ELSIF hb_a.up_min IS NOT NULL AND n_hb = 0 THEN
      c := 'app_suspended';
      d := 'The app stayed alive but iOS gave it no time to run from ' || hm
           || CASE WHEN n_disc > 0 THEN ', after the strap disconnected: ' || disc_reason ELSE '' END || '.';
    ELSIF p_to IS NULL THEN
      c := 'app_silent';
      d := 'Nothing from the app since ' || hm || ': it is not running, or the phone is off or offline.';
    ELSIF n_hb > 0 THEN
      c := 'app_killed';
      d := 'The app was mostly not running from ' || hm || ': iOS kept ending or suspending it.';
    ELSE
      c := 'app_killed';
      d := 'The app sent nothing from ' || hm || ' until the strap data came back; no heartbeat afterwards to say more.';
    END IF;
  ELSIF n_sync = top THEN
    c := 'history_blocking_live';
    d := 'The app was downloading old strap history (' || n_sync || ' of ' || n_hb
         || ' heartbeats said "Syncing history"), and live heart rate stays off until that download ends.';
  ELSIF n_conn = top THEN
    IF COALESCE(hb_b.strap_bat, 100) <= 3 THEN
      c := 'strap_battery_empty';
      d := 'The strap ran out of battery (' || hb_b.strap_bat || '% at ' || hm || ').';
    ELSE
      c := 'ble_disconnected';
      d := 'The Bluetooth link to the strap was down from ' || hm || ' and the app kept trying to reconnect'
           || CASE WHEN n_disc > 0 THEN ' (' || n_disc || ' drops; ' || disc_reason || ')' ELSE '' END
           || '. Strap battery ' || COALESCE(hb_b.strap_bat::text || '%', 'unknown') || '.';
    END IF;
  ELSIF n_hr0 = top THEN
    c := 'no_heart_rate';
    d := 'The strap stayed connected but sent no heart rate: off the wrist, or the sensor stopped measuring.';
  ELSIF n_hr = top AND n_hr > 0 THEN
    c := 'upload_failed';
    d := 'The app had heart rate but none of it reached the server (network or sign-in).';
  ELSE
    c := 'unknown';
    d := 'The app was running but its heartbeats do not say why no data arrived.';
  END IF;

  IF chg THEN extra := extra || ' The strap reported charging.'; END IF;
  IF fw_crash > 0 THEN extra := extra || ' The strap firmware logged a crash.'; END IF;
  IF c = 'app_killed' AND hb_b.mem_mb IS NOT NULL THEN
    extra := extra || ' App memory before: ' || hb_b.mem_mb || ' MB.';
  END IF;
  IF c IN ('app_killed', 'app_silent') AND hb_b.phone_bat IS NOT NULL AND hb_b.phone_bat <= 5 THEN
    c := 'phone_battery_dead';
    d := 'The phone was at ' || hb_b.phone_bat || '% at ' || hm || ' and most likely switched off.';
  END IF;

  cause := c;
  detail := d || extra;
  evidence := jsonb_strip_nulls(jsonb_build_object(
    'heartbeats', n_hb, 'alive_share', round(alive, 2), 'syncing', n_sync, 'connecting', n_conn, 'hr_zero', n_hr0, 'hr_ok', n_hr,
    'before', CASE WHEN hb_b.at IS NULL THEN NULL ELSE jsonb_build_object('at', hb_b.at, 'status', hb_b.status,
               'hr', hb_b.hr, 'strap_bat', hb_b.strap_bat, 'asleep', hb_b.asleep, 'up_min', hb_b.up_min,
               'phone_bat', hb_b.phone_bat, 'mem_mb', hb_b.mem_mb) END,
    'after', CASE WHEN hb_a.at IS NULL THEN NULL ELSE jsonb_build_object('at', hb_a.at, 'status', hb_a.status,
               'up_min', hb_a.up_min) END,
    'disconnects', n_disc, 'disconnect_reason', disc_reason,
    'crash', crash_line, 'prev_exit', prev_exit, 'strap_charging', chg, 'strap_fw_crash', fw_crash));
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.refresh_strap_outages(p_user_id uuid, p_since timestamptz DEFAULT now() - interval '36 hours')
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  g record; k record; n int := 0; keep timestamptz[] := '{}';
  rec_min int; is_night boolean;
BEGIN
  FOR g IN
    WITH m AS (SELECT DISTINCT date_trunc('minute', recorded_at) t FROM realtime_health
                WHERE user_id = p_user_id AND source = 'whoop_ble'
                  AND recorded_at >= p_since AND recorded_at < now() + interval '5 min'),
         l AS (SELECT lag(t) OVER (ORDER BY t) p, t FROM m)
    SELECT p + interval '1 minute' s, t e FROM l WHERE t - p >= interval '11 minutes'
    UNION ALL
    -- the ongoing silence, looked up on its own so a strap dead for days still shows
    SELECT x.last_t + interval '1 minute', NULL::timestamptz
      FROM (SELECT date_trunc('minute', max(recorded_at)) last_t FROM realtime_health
             WHERE user_id = p_user_id AND source = 'whoop_ble') x
     WHERE now() - x.last_t >= interval '11 minutes'
  LOOP
    SELECT * INTO k FROM classify_strap_gap(p_user_id, g.s, g.e);
    SELECT count(DISTINCT date_trunc('minute', recorded_at)) INTO rec_min FROM realtime_health
     WHERE user_id = p_user_id AND source <> 'whoop_ble'
       AND recorded_at >= g.s AND recorded_at < COALESCE(g.e, now());
    SELECT bool_or(extract(hour from x AT TIME ZONE 'Europe/Berlin') >= 22 OR extract(hour from x AT TIME ZONE 'Europe/Berlin') < 8)
      INTO is_night FROM generate_series(g.s, COALESCE(g.e, now()), interval '15 min') x;
    INSERT INTO strap_outages (user_id, started_at, ended_at, minutes, cause, detail, evidence, recovered_min, night, updated_at)
    VALUES (p_user_id, g.s, g.e, round(extract(epoch from (COALESCE(g.e, now()) - g.s)) / 60), k.cause, k.detail,
            k.evidence, rec_min, COALESCE(is_night, false), now())
    ON CONFLICT (user_id, started_at) DO UPDATE SET
      ended_at = EXCLUDED.ended_at, minutes = EXCLUDED.minutes, cause = EXCLUDED.cause, detail = EXCLUDED.detail,
      evidence = EXCLUDED.evidence, recovered_min = EXCLUDED.recovered_min, night = EXCLUDED.night, updated_at = now();
    keep := keep || g.s; n := n + 1;
  END LOOP;
  -- a silence that later filled in (offline queue flushed) is no longer an outage
  DELETE FROM strap_outages
   WHERE user_id = p_user_id AND started_at >= p_since + interval '1 minute' AND NOT (started_at = ANY (keep));
  RETURN n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.strap_outage_latest(p_user_id uuid, p_min_minutes integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE o record;
BEGIN
  IF auth.uid() IS NOT NULL AND auth.uid() <> p_user_id THEN RAISE EXCEPTION 'not allowed'; END IF;
  PERFORM refresh_strap_outages(p_user_id, now() - interval '36 hours');
  SELECT * INTO o FROM strap_outages
   WHERE user_id = p_user_id AND ended_at IS NOT NULL AND ended_at > now() - interval '3 hours'
     AND minutes >= p_min_minutes
   ORDER BY ended_at DESC LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'started_at', o.started_at, 'ended_at', o.ended_at, 'minutes', o.minutes, 'cause', o.cause,
    'detail', o.detail, 'recovered_min', o.recovered_min,
    'line', 'Strap silent ' || to_char(o.started_at AT TIME ZONE 'Europe/Berlin', 'HH24:MI') || '-'
            || to_char(o.ended_at AT TIME ZONE 'Europe/Berlin', 'HH24:MI') || ' ('
            || CASE WHEN o.minutes >= 60 THEN (o.minutes / 60) || ' h ' || (o.minutes % 60) || ' min'
                    ELSE o.minutes || ' min' END || '). ' || o.detail);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.strap_outage_latest(uuid, integer) TO authenticated;

SELECT cron.schedule('strap_outages_5min', '*/5 * * * *',
  $$SELECT public.refresh_strap_outages('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid, now() - interval '36 hours')$$);

-- The history dedup set as one JSON array. As a TABLE result PostgREST cut it at 1000 rows however wide
-- the Range header was (every sync logged minutes_with_data=1000), so stored minutes were uploaded again.
CREATE OR REPLACE FUNCTION public.minutes_with_realtime_data_packed(p_user_id uuid, p_since timestamptz, p_until timestamptz)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
    FROM (SELECT DISTINCT (extract(epoch FROM date_trunc('minute', recorded_at)))::bigint m
            FROM realtime_health
           WHERE user_id = p_user_id AND recorded_at >= p_since AND recorded_at < p_until) t
$function$;
GRANT EXECUTE ON FUNCTION public.minutes_with_realtime_data_packed(uuid, timestamptz, timestamptz) TO authenticated;
