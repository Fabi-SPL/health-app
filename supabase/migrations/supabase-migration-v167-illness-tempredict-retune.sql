-- v167 — illness ensemble retuned to the TemPredict feature ranking, and the
-- fabricated respiratory-rate history removed from its baseline.
--
-- TemPredict (Oura, n=63,153, 704 confirmed COVID+; AUC 0.819, 90%/80%
-- sens/spec, 2.75-day mean lead): HRV was the feature whose REMOVAL hurt the
-- model most, and continuous skin temperature added +4.9% AUC on top of
-- HR/HRV. Our ensemble had skin_temp as a bonus signal and respiratory rate as
-- mandatory — inverted from that evidence.
--
-- Worse: the client's respiratory rate was pinned at exactly 24.0 for the
-- feature's whole life (autocorrelation band-edge artifact, fixed on the
-- fix/health-data-truth-audit branch). 60 health_metrics rows carry that
-- constant. A CuSum comparing real breaths (~16-17) against a fabricated
-- median of 24 would either mask real alarms or manufacture fake ones for the
-- entire 74-day baseline window, so respiratory rate moves to BONUS until its
-- baseline is made of real nights — and the fabricated rows are nulled, since
-- exactly-24.0 here is an algorithm constant, not a measurement.

-- 1. Remove the artifact. Real EDR values are never exactly 24.000; the server
--    pipeline produces 16.6-17.5. Only the client wrote the band-edge constant.
update public.health_metrics
   set respiratory_rate = null
 where respiratory_rate = 24;

-- 2. Retune: mandatory = RHR + RMSSD + skin_temp (TemPredict's three),
--    bonus = respiratory rate + pNN50.
create or replace function public.illness_cusum_ensemble(p_user_id uuid, p_date date)
returns table(tier text, score numeric, signals jsonb)
language plpgsql
security definer
as $$
DECLARE
  k numeric := 0.8; h numeric := 5.0;       -- CuSum slack (0.8σ) + alarm threshold (h=5σ)
  d date; row_hm record;
  -- per-signal CuSum state + persistence counters
  s_rhr numeric:=0; s_rmssd numeric:=0; s_resp numeric:=0; s_pnn numeric:=0; s_skin numeric:=0;
  p_rhr int:=0; p_rmssd int:=0; p_skin int:=0;      -- consecutive-day alarm persistence (mandatory)
  z numeric; bl record;
  a_rhr boolean; a_rmssd boolean; a_resp boolean; a_pnn boolean; a_skin boolean;
  mand_alarms int; mand_persist int; bonus_alarms int; today_multi int;
  v_tier text; v_score numeric; v_sig jsonb; v_note text;
BEGIN
  -- Walk the trailing 16 days to build CuSum state up to p_date.
  FOR d IN SELECT generate_series(p_date - 15, p_date, '1 day')::date LOOP
    SELECT resting_hr, hrv_avg, respiratory_rate, pnn50_avg, skin_temp
      INTO row_hm FROM health_metrics
     WHERE user_id=p_user_id AND metric_date=d AND COALESCE(excluded,false)=false;
    IF row_hm IS NULL THEN CONTINUE; END IF;

    a_rhr:=false; a_rmssd:=false; a_resp:=false; a_pnn:=false; a_skin:=false;

    -- RHR (illness = UP). rsd floored at 1.5 bpm (min detectable change) so a steady signal
    -- can't manufacture huge z from a 1-unit blip. Same pattern for every signal below.
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'resting_hr',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.resting_hr>0 THEN
      z := (row_hm.resting_hr - bl.med)/GREATEST(bl.rsd, 1.5);
      s_rhr := GREATEST(0, s_rhr + z - k); a_rhr := s_rhr > h;
    END IF;
    -- RMSSD (illness = DOWN). TemPredict: the single most load-bearing feature.
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'hrv_avg',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.hrv_avg>0 THEN
      z := (bl.med - row_hm.hrv_avg)/GREATEST(bl.rsd, 3.0);
      s_rmssd := GREATEST(0, s_rmssd + z - k); a_rmssd := s_rmssd > h;
    END IF;
    -- skin_temp (illness = UP) — PROMOTED to mandatory (TemPredict +4.9% AUC).
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'skin_temp',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.skin_temp IS NOT NULL THEN
      z := (row_hm.skin_temp - bl.med)/GREATEST(bl.rsd, 0.15);
      s_skin := GREATEST(0, s_skin + z - k); a_skin := s_skin > h;
    END IF;
    -- Respiratory rate (illness = UP) — DEMOTED to bonus while its baseline
    -- rebuilds from real nights (pre-fix history was a fabricated constant).
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'respiratory_rate',d,74,14);
    IF bl.rsd IS NOT NULL AND row_hm.respiratory_rate>0 THEN
      z := (row_hm.respiratory_rate - bl.med)/GREATEST(bl.rsd, 0.8);
      s_resp := GREATEST(0, s_resp + z - k); a_resp := s_resp > h;
    END IF;
    -- pNN50 bonus (DOWN)
    SELECT * INTO bl FROM health_signal_baseline(p_user_id,'pnn50_avg',d,28,0);
    IF bl.rsd IS NOT NULL AND row_hm.pnn50_avg>0 THEN
      z := (bl.med - row_hm.pnn50_avg)/GREATEST(bl.rsd, 2.0);
      s_pnn := GREATEST(0, s_pnn + z - k); a_pnn := s_pnn > h;
    END IF;

    p_rhr   := CASE WHEN a_rhr THEN p_rhr+1 ELSE 0 END;
    p_rmssd := CASE WHEN a_rmssd THEN p_rmssd+1 ELSE 0 END;
    p_skin  := CASE WHEN a_skin THEN p_skin+1 ELSE 0 END;
  END LOOP;

  mand_alarms  := (a_rhr::int + a_rmssd::int + a_skin::int);
  bonus_alarms := (a_pnn::int + a_resp::int);
  mand_persist := GREATEST(CASE WHEN a_rhr THEN p_rhr ELSE 0 END,
                           CASE WHEN a_rmssd THEN p_rmssd ELSE 0 END,
                           CASE WHEN a_skin THEN p_skin ELSE 0 END);
  today_multi  := mand_alarms + bonus_alarms;
  v_score := round(LEAST(100, 100*(s_rhr+s_rmssd+s_skin)/(3*h*2)), 1);

  IF mand_alarms >= 2 AND mand_persist >= 3 THEN v_tier := 'red';
  ELSIF mand_alarms >= 1 OR today_multi >= 2      THEN v_tier := 'yellow';
  ELSE v_tier := 'green'; END IF;

  v_sig := jsonb_build_object(
    'cusum', jsonb_build_object('rhr',round(s_rhr,2),'rmssd',round(s_rmssd,2),'skin_temp',round(s_skin,2),
                                'resp',round(s_resp,2),'pnn50',round(s_pnn,2)),
    'alarms', jsonb_build_object('rhr',a_rhr,'rmssd',a_rmssd,'skin_temp',a_skin,'resp',a_resp,'pnn50',a_pnn),
    'mandatory_alarms', mand_alarms, 'persistence', mand_persist,
    'tuning', 'v167 TemPredict: mandatory rhr+rmssd+skin, resp demoted to bonus');

  SELECT count(*) INTO mand_alarms FROM illness_ground_truth_labels WHERE user_id=p_user_id;  -- reuse var as episode count
  v_note := CASE WHEN mand_alarms = 0 THEN 'baseline-only — no validated episodes yet'
                 ELSE format('n=%s labeled episodes — directional only', mand_alarms) END;

  UPDATE health_metrics SET illness_v2_score=v_score, illness_v2_tier=v_tier,
         illness_v2_note=v_note, illness_v2_signals=v_sig
   WHERE user_id=p_user_id AND metric_date=p_date;

  tier:=v_tier; score:=v_score; signals:=v_sig; RETURN NEXT;
END;
$$;
