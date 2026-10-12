-- v211: the health app pushes only health alerts that matter.
-- The app fires every nudge whose channels contain 'push'. HQ, business mail and several experiments wrote there
-- too, so the health app became everyone's push channel. A BEFORE INSERT gate now takes 'push' off any category
-- the policy mutes; the row is kept (in-app history, tablet feed), only the phone banner from the health app goes.
-- Rows the policy does not name keep their push, so a new safety alert is never muted by default.

CREATE TABLE IF NOT EXISTS public.health_push_policy (
  category          text PRIMARY KEY,
  push              boolean NOT NULL,
  reroute_to_tablet boolean NOT NULL DEFAULT false,
  why               text,
  updated_at        timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.health_push_policy (category, push, reroute_to_tablet, why) VALUES
  ('smart_wake',                  true,  false, 'the wake alarm'),
  ('ble_stream_dead',             true,  false, 'strap stopped sending'),
  ('ble_stream_dead_escalation',  true,  false, 'strap still down'),
  ('strap_battery_low',           true,  false, 'evening strap battery under 20%'),
  ('strap_battery_low_test',      true,  false, 'manual test of the battery push'),
  ('queue:health_write_alarm',    true,  false, 'health capture is dropping data'),
  ('hq',                          false, true,  'HQ and Claude sessions: not health, belongs in HQ/Lucid'),
  ('system',                      false, true,  'business mail and calls: not health'),
  ('queue:spiral_alert',          false, false, '"body called the brain": noisy, critical sound'),
  ('queue:ble_coverage',          false, false, 'daily coverage stat at 05:30, not actionable'),
  ('queue:smart_wake',            false, false, 'second copy of every wake alarm'),
  ('meal_detect',                 false, false, '"did you just eat?" turned off'),
  ('hangry_prewarning',           false, false, '"short fuse today": not a health alert'),
  ('local_biostate',              false, false, 'app''s own "🧪 arousal/intoxication/breathing changed" pings')
ON CONFLICT (category) DO UPDATE
  SET push = EXCLUDED.push, reroute_to_tablet = EXCLUDED.reroute_to_tablet, why = EXCLUDED.why, updated_at = now();

-- the app reads its own local categories (local_*) from here; it may read, never write
ALTER TABLE public.health_push_policy ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS health_push_policy_read ON public.health_push_policy;
CREATE POLICY health_push_policy_read ON public.health_push_policy FOR SELECT TO authenticated USING (true);
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.health_push_policy FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.nudge_push_category(p_source text, p_priority text, p_meta jsonb)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN p_source = 'cli'    THEN 'hq'
    WHEN p_source = 'system' THEN 'system'
    WHEN p_meta ? 'notification_queue_id' THEN 'queue:' || COALESCE((
      SELECT q.type FROM public.notification_queue q
       WHERE q.id = CASE WHEN p_meta->>'notification_queue_id' ~* '^[0-9a-f-]{36}$'
                         THEN (p_meta->>'notification_queue_id')::uuid END), '?')
    WHEN p_meta ? 'kind'     THEN p_meta->>'kind'
    WHEN p_priority = 'alarm' THEN 'smart_wake'
    ELSE COALESCE(p_source, '?')
  END
$function$;

CREATE OR REPLACE FUNCTION public.nudge_push_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  cat text;
  pol public.health_push_policy%ROWTYPE;
BEGIN
  IF NEW.channels IS NULL OR NOT ('push' = ANY (NEW.channels)) THEN
    RETURN NEW;
  END IF;
  BEGIN
    cat := public.nudge_push_category(NEW.source, NEW.priority, NEW.metadata);
    SELECT * INTO pol FROM public.health_push_policy WHERE category = cat;
    IF FOUND AND NOT pol.push THEN
      NEW.channels := array_remove(NEW.channels, 'push');
      IF pol.reroute_to_tablet AND NOT ('tablet' = ANY (NEW.channels)) THEN
        NEW.channels := NEW.channels || 'tablet'::text;
      END IF;
      NEW.metadata := COALESCE(NEW.metadata, '{}'::jsonb) || jsonb_build_object('push_muted', cat);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- the gate never blocks a nudge
  END;
  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS trg_nudge_push_gate ON public.nudges;
CREATE TRIGGER trg_nudge_push_gate BEFORE INSERT ON public.nudges
  FOR EACH ROW EXECUTE FUNCTION public.nudge_push_gate();

-- "did you just eat?" is off at the source too; the function stays for a later revival.
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'meal_detect_experiment';
