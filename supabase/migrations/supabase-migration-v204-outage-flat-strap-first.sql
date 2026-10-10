-- v204: a flat strap is classified before any app state.
-- On 2026-10-09 the strap died at 20:30 (0% in the last heartbeat) and the night was logged as app_killed,
-- because strap_battery_empty was only reachable while the app was alive and reconnecting. With no strap,
-- iOS stops waking the app, so the app always looks dead in exactly this case. Also reads the strap clock
-- the app logs on connect from v118 (strap_clock read=before_set): a clock more than a day off means the
-- strap shut down completely.
CREATE OR REPLACE FUNCTION public.classify_strap_gap(p_user_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
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
  clock_off bigint; back_at timestamptz;
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
  -- v201: always assign hb_a. With an open gap (p_to NULL) it was never assigned, and reading hb_a.up_min
  -- raised 'record hb_a is not assigned yet', so the logger failed exactly while the strap was silent.
  SELECT * INTO hb_a FROM app_heartbeats(p_user_id, t_end - interval '1 min', t_end + interval '20 min') h
   WHERE p_to IS NOT NULL
   ORDER BY h.at LIMIT 1;

  SELECT count(*), min(substring(b.value from 'reason=(.*?) code=') || ' (code ' || substring(b.value from 'code=([0-9]+)') || ')')
    INTO n_disc, disc_reason
    FROM bridge_logs b
   WHERE b.user_id = p_user_id AND b.category = 'evt_ble_disconnected'
     AND b.created_at BETWEEN p_from - interval '5 min' AND t_end;

  -- crash reports arrive on the next launch; their own at= says when the process died
  SELECT b.value INTO crash_line FROM bridge_logs b
   WHERE b.user_id = p_user_id AND b.category = 'app_crash'
     AND b.created_at >= p_from AND b.created_at < t_end + interval '2 hours'
   -- a report whose own window covers the silence's start wins; any other report sent on the next
   -- launch still names this death, because the app only reports past crashes when it starts again
   ORDER BY (substring(b.value from 'at=([^ ]+)')::timestamptz <= p_from + interval '15 min'
             AND substring(b.value from 'end=([^ ]+)')::timestamptz >= p_from - interval '3 min') IS TRUE DESC,
            b.created_at LIMIT 1;
  SELECT b.value INTO prev_exit FROM bridge_logs b
   WHERE b.user_id = p_user_id AND b.category = 'app_prev_exit'
     AND b.created_at >= p_from AND b.created_at < t_end + interval '30 min'
   ORDER BY b.created_at LIMIT 1;

  SELECT bool_or(w.event_type = 'charging_on'), count(*) FILTER (WHERE w.event_type = 'memfault_crash')
    INTO chg, fw_crash
    FROM whoop_events w
   WHERE w.user_id = p_user_id AND w.event_type IN ('charging_on', 'memfault_crash')
     AND w.recorded_at BETWEEN p_from - interval '5 min' AND t_end;

  -- v204: the strap's own clock read on the next connect; a reset clock (1971) means it shut down completely
  SELECT substring(b.value from 'offset_s=(-?[0-9]+)')::bigint, b.created_at INTO clock_off, back_at FROM bridge_logs b
   WHERE b.user_id = p_user_id AND b.category = 'strap_clock' AND b.value LIKE 'read=before_set%'
     AND b.created_at BETWEEN p_from AND t_end + interval '20 min'
   ORDER BY b.created_at LIMIT 1;
  IF back_at IS NULL AND p_to IS NOT NULL THEN
    SELECT b.created_at INTO back_at FROM bridge_logs b
     WHERE b.user_id = p_user_id AND b.category = 'evt_ble_connected'
       AND b.created_at BETWEEN p_from + interval '3 min' AND t_end + interval '20 min'
     ORDER BY b.created_at LIMIT 1;
  END IF;

  -- a running app uploads a heartbeat every ~2 min; a handful across a long silence means it was mostly dead
  alive := n_hb / GREATEST(1, gap_min / 2);
  top := GREATEST(n_sync, n_conn, n_hr0, n_hr);
  IF n_hb > 0 AND alive < 0.25 THEN
    extra := ' The app was only alive for about ' || (n_hb * 2) || ' min of it, and then it was mostly '
             || CASE top WHEN n_sync THEN 'downloading old history (live HR off)' WHEN n_conn THEN 'reconnecting'
                         WHEN n_hr0 THEN 'connected with no heart rate' ELSE 'streaming' END || '.';
  END IF;

  -- v204: a flat strap comes first. With no strap to talk to, iOS stops waking the app, so the app looks
  -- killed or suspended too; on 2026-10-09 this branch never ran and the dead strap was logged as app_killed.
  -- Battery alone is not enough: at 1-3 % the strap can still be connected and syncing (19:02, 20:00 that day).
  IF (COALESCE(hb_b.strap_bat, 100) <= 3 AND (n_hb = 0 OR alive < 0.25 OR n_conn = top))
     OR COALESCE(clock_off, 0) > 86400 THEN
    c := 'strap_battery_empty';
    d := 'The strap ran out of battery (' || COALESCE(hb_b.strap_bat::text || '%', 'its clock had reset') || ' at ' || hm
         || ') and switched off'
         || CASE WHEN back_at IS NOT NULL THEN ' until it was charged and reconnected at '
                   || to_char(back_at AT TIME ZONE 'Europe/Berlin', 'HH24:MI') ELSE '' END
         || '. A switched-off strap records nothing, so this stretch cannot be recovered.';
  ELSIF n_hb = 0 OR alive < 0.25 THEN
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
    'crash', crash_line, 'prev_exit', prev_exit, 'strap_charging', chg, 'strap_fw_crash', fw_crash,
    'strap_clock_offset_s', clock_off, 'strap_back_at', back_at));
  RETURN NEXT;
END;
$function$;
