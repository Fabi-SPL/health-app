-- migration v122_circadian_phase.sql
-- Circadian phase map for Fabi (single-user, bespoke). From 45 days of his
-- realtime_health HR rhythm (Berlin): nadir ~03:00 (HR ~56), peak ~17:00
-- (HR ~91). He is a LATE chronotype: natural wake ~08:30, i.e. ~5h after the
-- HR nadir, NOT the textbook +2h. The old estimate_circadian_anchor told the
-- alarm "optimal wake = nadir+2 = 05:00" which is wrong for him by 3+ hours.
--
-- Phase boundaries are HIS measured values (refresh if his rhythm drifts).
-- Returns the current phase + a plain note ("when is my body in X state") and
-- the markers the smart alarm should use (natural_wake_hour 8.5, never 5-6).
-- Applied live via /pg/query (DB is source of truth, this file is the record).

CREATE OR REPLACE FUNCTION public.circadian_phase(p_user_id uuid, p_now timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE h numeric; phase text; note text;
  nadir int := 3; peak int := 17; nat_wake numeric := 8.5;
BEGIN
  h := extract(hour from p_now AT TIME ZONE 'Europe/Berlin') + extract(minute from p_now AT TIME ZONE 'Europe/Berlin')/60.0;
  IF h >= 1 AND h < 6 THEN phase:='deep_night'; note:='Autonomic floor (HR ~56). Deepest rest. Nothing should wake you here.';
  ELSIF h >= 6 AND h < 11 THEN phase:='morning_rise'; note:='Climbing out. Warming up, not sharp yet. Natural wake ~08:30; do not force earlier.';
  ELSIF h >= 11 AND h < 15 THEN phase:='daytime_plateau'; note:='Steady daytime baseline. Good for focused work.';
  ELSIF h >= 15 AND h < 18 THEN phase:='peak_activation'; note:='Your peak (HR tops ~5pm). Most wired and capable. Hard tasks and training land best now.';
  ELSIF h >= 18 AND h < 22 THEN phase:='evening_decline'; note:='Coming down off the peak. Ramp intensity down.';
  ELSE phase:='wind_down'; note:='Heading for sleep. Screens down, let HR fall.';
  END IF;
  RETURN jsonb_build_object('now_h',round(h,2),'phase',phase,'note',note,
    'nadir_hour',nadir,'peak_hour',peak,'natural_wake_hour',nat_wake,'chronotype','late',
    'chronotype_note','Late chronotype: nadir ~03:00, natural wake ~08:30 (body wakes ~5h after the HR low, not the textbook 2h). Alarm circadian wake should be ~08:00-09:00, never 05:00-06:00.');
END;$f$;

COMMENT ON FUNCTION public.circadian_phase IS
'v122: current circadian phase + markers from Fabi''s measured HR rhythm (nadir 03:00, peak 17:00, late chronotype, natural wake 08:30). Feeds the smart alarm the correct circadian wake.';
