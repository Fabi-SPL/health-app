-- migration v121_back_to_sleep_coach.sql
-- Smart Alarm — in-window "Go Back or Get Up?" coach.
--
-- When Fabi wakes BEFORE his sleep target (e.g. 6:50am pee-wake) and opens the
-- app, this RPC returns a personalized verdict: go back down (and the app arms a
-- gentle wake at his next cycle boundary) or get up (no point — he'd only wake
-- mid-cycle, groggier). Decided from his personalized sleep target
-- (target_sleep_duration) + current 7-day sleep debt (compute_sleep_debt) + a
-- 90-min cycle. The app passes p_sleep_start (HealthEngine.sleepStartTime).
--
-- Decision ladder (first match wins):
--   slept >= target-10m            -> get_up  (full night already banked)
--   minutes_left <= 0              -> get_up  (already at target wake)
--   minutes_left >= 85             -> go_back (room for a full cycle)
--   minutes_left < 55              -> get_up  (would wake mid-cycle = groggier)
--   55..84 gray  + debt >= 1.0h    -> go_back (the extra REM is worth it)
--   55..84 gray  + low debt        -> get_up  (lean — you've got what you need)
--
-- Applied live via /pg/query (consistent with the v108+ pattern: DB is the
-- source of truth, this file is the record).

CREATE OR REPLACE FUNCTION public.plan_back_to_sleep(
  p_user_id uuid,
  p_sleep_start timestamptz,
  p_now timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE
  target_h numeric; target_wake timestamptz; slept_min numeric; left_min numeric;
  debt_h numeric; cycle int := 90; verdict text; headline text; detail text;
  wake_at timestamptz; wake_label text; slept_label text;
BEGIN
  SELECT t.target_h INTO target_h FROM target_sleep_duration(p_user_id) t;
  target_h := COALESCE(target_h, 8.5);
  target_wake := p_sleep_start + make_interval(mins => round(target_h*60)::int);
  slept_min := EXTRACT(EPOCH FROM (p_now - p_sleep_start))/60.0;
  left_min := EXTRACT(EPOCH FROM (target_wake - p_now))/60.0;
  debt_h := COALESCE(compute_sleep_debt(p_user_id), 0);
  wake_label := to_char(target_wake AT TIME ZONE 'Europe/Berlin','HH24:MI');
  slept_label := floor(slept_min/60)::text || 'h ' || lpad((round(slept_min)::int % 60)::text,2,'0') || 'm';

  IF slept_min >= target_h*60 - 10 THEN
    verdict := 'get_up'; headline := 'You''re good — get up';
    detail := 'You''ve banked ' || slept_label || ' — basically your full target. More now is bonus, not rest. Start your day.';
    wake_at := NULL;
  ELSIF left_min <= 0 THEN
    verdict := 'get_up'; headline := 'You''re good — get up';
    detail := 'You''re right at your wake time. You woke fresh — ride it, don''t restart a cycle.';
    wake_at := NULL;
  ELSIF left_min >= cycle - 5 THEN
    verdict := 'go_back'; headline := 'Go back down';
    detail := 'About ' || round(left_min)::text || ' min of real sleep left — room for a full cycle. I''ll wake you gently at ' || wake_label || '.';
    wake_at := target_wake;
  ELSIF left_min < 55 THEN
    verdict := 'get_up'; headline := 'You''re done — get up';
    detail := 'Only ' || round(left_min)::text || ' min left. Going back now means waking mid-cycle, groggier than you are. You woke fresh — ride it.';
    wake_at := NULL;
  ELSE
    IF debt_h >= 1.0 THEN
      verdict := 'go_back'; headline := 'Go back down';
      detail := 'About ' || round(left_min)::text || ' min left, and you''re carrying ' || round(debt_h,1)::text || 'h of sleep debt — the extra REM is worth it. I''ll wake you at ' || wake_label || '.';
      wake_at := target_wake;
    ELSE
      verdict := 'get_up'; headline := 'Your call — lean get up';
      detail := 'About ' || round(left_min)::text || ' min left. You''ve basically got what you need, and a short half-cycle risks grogginess. I''d get up — but your call.';
      wake_at := NULL;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'verdict', verdict, 'headline', headline, 'detail', detail,
    'wake_at', CASE WHEN wake_at IS NULL THEN NULL ELSE to_char(wake_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
    'wake_label', wake_label, 'minutes_left', round(left_min)::int,
    'slept_min', round(slept_min)::int, 'slept_h', round(slept_min/60.0,2),
    'debt_h', round(debt_h,2), 'target_h', round(target_h,2)
  );
END;$f$;

COMMENT ON FUNCTION public.plan_back_to_sleep IS
'v121 smart-alarm: in-window go-back/get-up verdict from personalized sleep target + 7-day debt + 90-min cycle. App passes sleep_start; returns jsonb {verdict, headline, detail, wake_at, wake_label, minutes_left, slept_h, debt_h, target_h}.';
