-- v174 — the alarm woke Fabi while he was already awake.
--
-- current_deep_probability() only scores how DEEP sleep is. There is no awake
-- class anywhere in the oracle, so lying still and fully conscious scores as the
-- most wake-eligible state possible: dp collapses under 0.40 and the opportunistic
-- branch fires.
--
-- 2026-08-12 is the clean case. realtime_health carried sleep_stage='awake' on
-- every minute from 06:55 to 07:24 (HR 51-55). The alarm fired 07:20 anyway with
-- reason='target_reached'. Twenty-one seconds later the iOS guard logged
-- evt_alarm_pulse_skip reason=already-awake hr=51 — the phone knew, the server
-- never asked. Same shape 2026-07-21 and 2026-07-28.
--
-- Fix: consult the stage stream the strap is already writing. Deliberately scoped
-- to the OPPORTUNISTIC branch only. The backstop still fires no matter what, so a
-- false "he's awake" read can never turn into oversleeping.

CREATE OR REPLACE FUNCTION public.should_wake_now(
  p_user_id uuid, p_win_start timestamptz, p_win_end timestamptz,
  p_at timestamptz DEFAULT now())
RETURNS TABLE(wake boolean, wake_score integer, deep_prob numeric, reason text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  dp numeric; dp_prev numeric;
  awake_min int; obs_min int;
BEGIN
  dp := current_deep_probability(p_user_id, p_at);
  deep_prob := dp;
  wake_score := CASE WHEN dp IS NULL THEN NULL ELSE ROUND(100*(1-dp)) END;

  -- v174: what did the strap actually say about the last five minutes?
  SELECT count(*) FILTER (WHERE sleep_stage = 'awake'), count(*)
    INTO awake_min, obs_min
  FROM (
    SELECT DISTINCT ON (date_trunc('minute', recorded_at))
           date_trunc('minute', recorded_at) m, sleep_stage
    FROM realtime_health
    WHERE user_id = p_user_id
      AND recorded_at >= p_at - interval '5 minutes'
      AND recorded_at <  p_at
      AND sleep_stage IS NOT NULL
    ORDER BY date_trunc('minute', recorded_at), recorded_at DESC
  ) z;

  IF p_at >= p_win_end THEN
    -- backstop / force-wake. Fires regardless of the awake read: missing the
    -- deadline is the one failure that actually costs him something.
    wake := true;  wake_score := 100; deep_prob := NULL;
    reason := '⏰ deadline reached — waking now';
  ELSIF p_at < p_win_start THEN
    wake := false; reason := 'before wake window';
  ELSIF COALESCE(obs_min, 0) >= 3 AND awake_min * 2 > obs_min THEN
    -- Majority of the observed minutes say awake. Nothing to wake him from.
    wake := false;
    reason := format('☀️ already awake (%s of last %s min) — no alarm needed', awake_min, obs_min);
  ELSIF dp IS NULL THEN
    wake := false; reason := 'no live data';
  ELSIF dp < 0.40 THEN
    -- Require the light-sleep read to PERSIST (also light ~3 min earlier) so a
    -- single transient arousal right after deep sleep can't force an early
    -- wake (finding #22). Hold otherwise; the deadline branch is the backstop.
    dp_prev := current_deep_probability(p_user_id, p_at - interval '3 minutes');
    IF dp_prev IS NOT NULL AND dp_prev < 0.40 THEN
      wake := true;  reason := '🟢 light sleep (sustained) — ideal moment to wake';
    ELSE
      wake := false; reason := '🟡 light but not yet sustained — hold, recheck shortly';
    END IF;
  ELSE
    wake := false; reason := '🛑 deep sleep — hold, recheck shortly';
  END IF;
  RETURN NEXT;
END;$function$;
