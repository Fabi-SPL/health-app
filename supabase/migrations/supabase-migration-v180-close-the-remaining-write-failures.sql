-- v180 — close every remaining write path that was silently losing data
--
-- Kong request log, 7 days, POST/PATCH by status. v178 killed the realtime_health
-- 400s; these are what was left underneath:
--
--   knowledge_entries              869 x 400   (62% of all writes failing)
--   ride_telemetry                 978 x 400   (32% failing)
--   rpc/sleep_duration_baseline     94 x 404   (function exists, arity mismatch)
--   cron auto_exclude_broken_night   5 x fail  (ambiguous column, 5 of last 7 days)
--
-- Each one is a different mechanism, same outcome: data thrown away with no
-- surface anywhere Fabi would see it.

-- 1. knowledge_entries — the iOS app pushes its own debug log batches with
--    category 'device_log' (SupabaseClient.pushAppLog). That value was never in
--    the CHECK, so every remote-debug batch has been rejected. The one telemetry
--    channel meant to make the app diagnosable was itself silently broken.
ALTER TABLE public.knowledge_entries
  DROP CONSTRAINT IF EXISTS knowledge_entries_category_check;

ALTER TABLE public.knowledge_entries
  ADD CONSTRAINT knowledge_entries_category_check
  CHECK (category = ANY (ARRAY[
    'lucid_dev','business','personal','health',
    'weekly_summary','decision','learning',
    'device_log'
  ]));

-- device_log rows are diagnostics, not memory. They carry no embedding, so
-- semantic recall already skips them; this index keeps the plain-text and
-- date-ordered queries off the memory corpus too.
CREATE INDEX IF NOT EXISTS idx_knowledge_entries_not_device_log
  ON public.knowledge_entries (user_id, entry_date DESC)
  WHERE category <> 'device_log';

-- 2. ride_telemetry — activity_id is NOT NULL with an FK to activities(id), but
--    LucidRide streams telemetry before an activity row exists (and after it
--    ends). 978 samples in 7 days were rejected for a bookkeeping field.
--    The FK still holds when the value is present; NULL simply means
--    "not attached to a ride yet".
ALTER TABLE public.ride_telemetry ALTER COLUMN activity_id DROP NOT NULL;

-- 3. sleep_duration_baseline — signature is (p_user_id uuid, p_days integer)
--    with no default, so every caller passing only p_user_id got a 404 from
--    PostgREST (no matching overload). 14 nights of baseline is the value the
--    callers were assuming.
CREATE OR REPLACE FUNCTION public.sleep_duration_baseline(
  p_user_id uuid, p_days integer DEFAULT 14
)
RETURNS TABLE(mean_hours numeric, sd_hours numeric, n_nights integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
  SELECT round(avg(sleep_hours)::numeric, 2),
         round(coalesce(stddev_samp(sleep_hours), 0)::numeric, 2),
         count(*)::integer
  FROM public.health_metrics
  WHERE user_id = p_user_id
    AND metric_date > current_date - p_days
    AND sleep_hours IS NOT NULL
    AND sleep_hours > 0
    AND coalesce(excluded, false) = false;
$fn$;

-- 4. auto_exclude_broken_day — the OUT parameter is named metric_date, which
--    collides with health_metrics.metric_date inside the UPDATE. Postgres
--    refuses the ambiguity, so the nightly job failed 5 of the last 7 days and
--    no broken night was ever excluded. Gap nights kept their recovery and
--    body-battery scores, computed from data that was not there.
CREATE OR REPLACE FUNCTION public.auto_exclude_broken_day(
  p_user_id uuid, p_date date, p_apply boolean DEFAULT false
)
RETURNS TABLE(metric_date date, core_rows bigint, sleep_hours numeric,
              would_exclude boolean, reason text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_rows bigint; v_sleep numeric; v_excl boolean; v_reason text;
BEGIN
  SELECT count(*) INTO v_rows FROM realtime_health rh
   WHERE rh.user_id = p_user_id AND rh.heart_rate > 20
     AND rh.recorded_at >= ((p_date::text||' 01:00')::timestamp AT TIME ZONE 'Europe/Berlin')
     AND rh.recorded_at <  ((p_date::text||' 05:00')::timestamp AT TIME ZONE 'Europe/Berlin');

  SELECT hm.sleep_hours INTO v_sleep FROM health_metrics hm
   WHERE hm.user_id = p_user_id AND hm.metric_date = p_date;

  v_excl := (v_rows < 200) AND (v_sleep IS NULL OR v_sleep < 3);
  v_reason := CASE WHEN v_excl THEN
    format('Auto-excluded: only %s realtime rows in core sleep 01:00-05:00 (normal 1000-1800) + no usable sleep window. BLE dropout / strap not streaming.', v_rows)
    ELSE NULL END;

  IF p_apply AND v_excl THEN
    UPDATE health_metrics hm SET
      excluded = true, exclude_reason = v_reason,
      body_battery = NULL, body_battery_anchor = NULL, bb_effective = NULL,
      strain_score = NULL, recovery_score = NULL, readiness_score = NULL
    WHERE hm.user_id = p_user_id
      AND hm.metric_date = p_date          -- qualified: the OUT param shadows this
      AND hm.excluded = false;
  END IF;

  RETURN QUERY SELECT p_date, v_rows, v_sleep, v_excl, v_reason;
END;$function$;

-- 1b. the same push also sets source_type='device_log', which the source_type
--     CHECK rejected as well. Both constraints had to move, or the write still
--     dies. Caught by re-running the probe after the category fix.
ALTER TABLE public.knowledge_entries
  DROP CONSTRAINT IF EXISTS knowledge_entries_source_type_check;

ALTER TABLE public.knowledge_entries
  ADD CONSTRAINT knowledge_entries_source_type_check
  CHECK (source_type = ANY (ARRAY[
    'task','brain_dump','code_session','cowork_session','habit','mood_energy',
    'supplement','manual','archiver','report','finding','display_note',
    'chatgpt_import','summary',
    'device_log'
  ]));
