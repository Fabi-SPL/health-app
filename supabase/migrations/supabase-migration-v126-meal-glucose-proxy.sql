-- migration v126_meal_glucose_proxy.sql
-- "Glucose proxy" via TEXT meal logging (single-user, bespoke, EXPERIMENTAL).
--
-- Fabi will not photo-log meals. He WILL type "I ate lasagna". So the design is:
--   text -> rough carb/glycemic estimate -> match the post-meal HR bump in realtime_health.
-- Honest ceiling: a RELATIVE meal-impact proxy ("doner hits harder than rice"), NOT
-- absolute blood glucose in mg/dL. No CGM, so this is heart-rate-as-a-stand-in.
--
-- Four pieces (all server-side; the public app only calls the RPCs, stores no logic):
--
-- 1. food_glycemic_ref  -- bespoke keyword table of HIS staples (51 rows). Each row:
--      keyword, label, typical portion_g, net_carbs_g, kcal, gi_band, glycemic_load.
--      Zero-cost lookup, no LLM. Extend by INSERTing rows as his diet changes.
--
-- 2. estimate_meal_from_text(p_text) -> jsonb
--      Lowercases the text, LIKE-matches every keyword, sums net carbs / kcal / GL.
--      Crude quantity scaling: "2/two/double"->2x, "large/big"->1.4x, "small"->0.6x
--      (applies to the whole meal, a known v1 limitation, no per-item quantities).
--      confidence: 'estimate' (carb food matched) / 'low' / 'none' (nothing recognised,
--      returned honestly rather than faked). gi_band high>=30 / medium>=12 / low GL.
--      Quantity regex uses (^|[^a-z]) boundaries, NOT \m\M (the latter gets mangled by
--      the /pg/query JSON double-escaping and silently never fires).
--
-- 3. log_meal_text(p_user_id, p_text, p_when) -> jsonb   [VOLATILE, inserts]
--      Runs the estimate, reshapes items into the food_entries shape (carbs_g key that
--      meal_hr_response reads), INSERTs a food_entry (source='text'). Returns id+estimate.
--
-- 4. meal_hr_response(p_user_id, p_meal_id) -> jsonb
--      The novel part: post-prandial HR from 722k realtime_health rows.
--      pre-meal resting baseline (-25..-5 min) vs post-meal window (+30..+90 min),
--      then CIRCADIAN-DETRENDED by subtracting his own hourly-median HR drift across the
--      window (so a dinner at his 17:00 HR peak is not mistaken for a food bump).
--      REST GATE: verdict 'clean' only if pre_var < 10 AND pre_hr <= circadian median +12,
--      else 'active_unreliable' (he was moving, bump is activity not digestion) or
--      'no_coverage'. Validated: lasagna (58g) clean +9.2 bpm; espresso clean +14.2;
--      the 8 post-activity logs correctly rejected.
--
-- 5. meal_impact_ranking(p_user_id, p_days) -> jsonb
--      Aggregates only 'clean' responses, ranks by adj_bump_bpm ("what hits hardest").
--      Honestly reports the clean-sample count and asks for more resting logs when < 3.
--
-- LIMITATION stated to Fabi: HR is a weak glucose stand-in (confounded by caffeine,
-- stress, position). This is a directional "which meals spike me" tool, and it needs
-- him to log meals while resting to gather clean readings. Applied live via /pg/query.

CREATE TABLE IF NOT EXISTS public.food_glycemic_ref (
  id serial PRIMARY KEY, keyword text NOT NULL, label text NOT NULL,
  portion_g int NOT NULL, net_carbs_g numeric NOT NULL, kcal int NOT NULL,
  gi_band text NOT NULL, glycemic_load numeric NOT NULL,
  is_drink boolean DEFAULT false, is_alcohol boolean DEFAULT false);

-- Seed = Fabi's staples (German + his logged foods). TRUNCATE+re-seed is safe (ref data).
TRUNCATE public.food_glycemic_ref RESTART IDENTITY;
INSERT INTO public.food_glycemic_ref (keyword,label,portion_g,net_carbs_g,kcal,gi_band,glycemic_load,is_drink,is_alcohol) VALUES
 ('lasagna','Lasagna',450,55,740,'high',38,false,false),
 ('lasagne','Lasagna',450,55,740,'high',38,false,false),
 ('pizza','Pizza',300,80,850,'high',56,false,false),
 ('doner','Doner / Kebab',400,65,750,'high',42,false,false),
 ('döner','Doner / Kebab',400,65,750,'high',42,false,false),
 ('kebab','Doner / Kebab',400,65,750,'high',42,false,false),
 ('pasta','Pasta',350,70,520,'medium',39,false,false),
 ('fusilli','Pasta',350,70,520,'medium',39,false,false),
 ('spaghetti','Spaghetti',350,72,540,'medium',40,false,false),
 ('rice','Rice',250,60,330,'high',45,false,false),
 ('reis','Rice',250,60,330,'high',45,false,false),
 ('fries','Fries',200,55,430,'high',43,false,false),
 ('pommes','Fries',200,55,430,'high',43,false,false),
 ('potato','Potatoes',300,50,260,'high',40,false,false),
 ('kartoffel','Potatoes',300,50,260,'high',40,false,false),
 ('bread','Bread',80,38,210,'high',28,false,false),
 ('brot','Bread',80,38,210,'high',28,false,false),
 ('brötchen','Bread roll',60,28,160,'high',22,false,false),
 ('toast','Toast',60,26,160,'high',20,false,false),
 ('burger','Burger',280,42,640,'high',27,false,false),
 ('oats','Oats',60,40,230,'low',16,false,false),
 ('haferflocken','Oats',60,40,230,'low',16,false,false),
 ('müsli','Muesli',60,38,240,'medium',21,false,false),
 ('banana','Banana',120,25,105,'medium',13,false,false),
 ('banane','Banana',120,25,105,'medium',13,false,false),
 ('apple','Apple',180,21,95,'low',8,false,false),
 ('chicken','Chicken (lean)',200,0,330,'low',0,false,false),
 ('hähnchen','Chicken (lean)',200,0,330,'low',0,false,false),
 ('egg','Eggs',100,1,150,'low',0,false,false),
 ('ei','Eggs',100,1,150,'low',0,false,false),
 ('steak','Steak',250,0,500,'low',0,false,false),
 ('salad','Salad',200,8,120,'low',3,false,false),
 ('salat','Salad',200,8,120,'low',3,false,false),
 ('protein shake','Protein shake',400,8,180,'low',4,true,false),
 ('shake','Protein shake',400,8,180,'low',4,true,false),
 ('yogurt','Yogurt',200,12,140,'low',6,false,false),
 ('joghurt','Yogurt',200,12,140,'low',6,false,false),
 ('chocolate','Chocolate',50,28,270,'medium',16,false,false),
 ('schokolade','Chocolate',50,28,270,'medium',16,false,false),
 ('ice cream','Ice cream',120,30,250,'medium',18,false,false),
 ('eis','Ice cream',120,30,250,'medium',18,false,false),
 ('cola','Cola / soft drink',330,35,140,'high',23,true,false),
 ('soda','Cola / soft drink',330,35,140,'high',23,true,false),
 ('juice','Juice',250,26,110,'high',16,true,false),
 ('beer','Beer',500,15,210,'medium',8,true,true),
 ('bier','Beer',500,15,210,'medium',8,true,true),
 ('radler','Radler',500,25,230,'high',14,true,true),
 ('wine','Wine',150,4,125,'low',2,true,true),
 ('wein','Wine',150,4,125,'low',2,true,true),
 ('whiskey','Whiskey',88,0,234,'low',0,true,true),
 ('whisky','Whiskey',88,0,234,'low',0,true,true);

CREATE OR REPLACE FUNCTION public.estimate_meal_from_text(p_text text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE tl text; mult numeric := 1; v_carbs numeric := 0; v_kcal int := 0; v_gl numeric := 0;
  matched jsonb := '[]'::jsonb; conf text; alc boolean := false; r record; hit boolean := false;
BEGIN
  tl := lower(coalesce(p_text,''));
  IF tl ~ '(^|[^0-9a-z])(2|two|zwei|double|doppel)([^0-9a-z]|$)' THEN mult := 2;
  ELSIF tl ~ '(^|[^0-9a-z])(3|three|drei)([^0-9a-z]|$)' THEN mult := 3;
  ELSIF tl ~ '(^|[^a-z])(large|big|gross|große|grosse|xl)([^a-z]|$)' THEN mult := 1.4;
  ELSIF tl ~ '(^|[^a-z])(small|klein|kleine|half|halbe)([^a-z]|$)' THEN mult := 0.6; END IF;
  FOR r IN
    SELECT DISTINCT ON (g.label) g.label AS label, g.net_carbs_g AS nc, g.kcal AS kc, g.glycemic_load AS glo, g.gi_band AS band, g.is_alcohol AS alcf
    FROM public.food_glycemic_ref g WHERE tl LIKE '%'||g.keyword||'%' ORDER BY g.label, length(g.keyword) DESC
  LOOP
    hit := true; v_carbs := v_carbs + r.nc*mult; v_kcal := v_kcal + round(r.kc*mult); v_gl := v_gl + r.glo*mult;
    IF r.alcf THEN alc := true; END IF;
    matched := matched || jsonb_build_object('name',r.label,'net_carbs_g',r.nc*mult,'kcal',round(r.kc*mult),'gi_band',r.band,'is_alcohol',r.alcf);
  END LOOP;
  conf := CASE WHEN NOT hit THEN 'none' WHEN jsonb_array_length(matched) >= 1 AND v_carbs > 0 THEN 'estimate' ELSE 'low' END;
  RETURN jsonb_build_object('input',p_text,'multiplier',mult,'items',matched,
    'net_carbs_g',round(v_carbs),'kcal',v_kcal,'glycemic_load',round(v_gl),
    'gi_band',CASE WHEN v_gl>=30 THEN 'high' WHEN v_gl>=12 THEN 'medium' ELSE 'low' END,
    'is_alcohol',alc,'confidence',conf,
    'note',CASE WHEN NOT hit THEN 'Did not recognise any food in that. Add it to the reference or log carbs manually.'
      ELSE format('~%s g net carbs, glycemic load ~%s (%s). Rough estimate from text.', round(v_carbs), round(v_gl),
        CASE WHEN v_gl>=30 THEN 'hits hard' WHEN v_gl>=12 THEN 'moderate' ELSE 'gentle' END) END);
END;$f$;
COMMENT ON FUNCTION public.estimate_meal_from_text IS 'v126: zero-cost text->carb/glycemic estimate via bespoke keyword lookup (food_glycemic_ref). Feeds log_meal_text + meal_hr_response. Relative meal-impact proxy, not absolute mg/dL.';

CREATE OR REPLACE FUNCTION public.meal_hr_response(p_user_id uuid, p_meal_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE t0 timestamptz; carbs numeric; fiber numeric; kcal int; nm text; alc boolean;
  pre_hr numeric; pre_var numeric; post_mean numeric; post_peak numeric; n_post int; n_pre int;
  h_pre int; h_post int; circ_pre numeric; circ_post numeric; circ_drift numeric;
  raw_bump numeric; adj_bump numeric; gl numeric; verdict text; clean boolean; note text;
BEGIN
  SELECT captured_at, total_kcal, COALESCE(caption, items->0->>'name'),
    COALESCE((SELECT sum((i->>'carbs_g')::numeric) FROM jsonb_array_elements(items) i),0),
    COALESCE((SELECT sum((i->>'fiber_g')::numeric) FROM jsonb_array_elements(items) i),0),
    COALESCE((SELECT bool_or((i->>'is_alcohol')::boolean) FROM jsonb_array_elements(items) i),false)
    INTO t0, kcal, nm, carbs, fiber, alc FROM food_entries WHERE id=p_meal_id AND user_id=p_user_id;
  IF t0 IS NULL THEN RETURN jsonb_build_object('error','no meal'); END IF;
  SELECT avg(heart_rate), COALESCE(stddev(heart_rate),0), count(*) INTO pre_hr, pre_var, n_pre
    FROM realtime_health WHERE user_id=p_user_id AND heart_rate>0 AND recorded_at BETWEEN t0 - interval '25 min' AND t0 - interval '5 min';
  SELECT avg(heart_rate), max(heart_rate), count(*) INTO post_mean, post_peak, n_post
    FROM realtime_health WHERE user_id=p_user_id AND heart_rate>0 AND recorded_at BETWEEN t0 + interval '30 min' AND t0 + interval '90 min';
  IF pre_hr IS NULL OR post_mean IS NULL OR n_post < 5 OR n_pre < 3 THEN
    RETURN jsonb_build_object('verdict','no_coverage','meal',nm,'note','Not enough HR data around this meal to read a response.'); END IF;
  h_pre := extract(hour FROM (t0 - interval '15 min') AT TIME ZONE 'Europe/Berlin')::int;
  h_post := extract(hour FROM (t0 + interval '60 min') AT TIME ZONE 'Europe/Berlin')::int;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY heart_rate) INTO circ_pre FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate>0 AND extract(hour FROM recorded_at AT TIME ZONE 'Europe/Berlin')::int = h_pre;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY heart_rate) INTO circ_post FROM realtime_health
    WHERE user_id=p_user_id AND heart_rate>0 AND extract(hour FROM recorded_at AT TIME ZONE 'Europe/Berlin')::int = h_post;
  circ_drift := COALESCE(circ_post,0) - COALESCE(circ_pre,0);
  raw_bump := post_mean - pre_hr; adj_bump := raw_bump - circ_drift; gl := GREATEST(0, carbs - fiber);
  clean := (pre_var < 10 AND pre_hr <= COALESCE(circ_pre, pre_hr) + 12);
  IF NOT clean THEN verdict := 'active_unreliable';
    note := format('%s: you were moving around this meal (pre-HR %s, jitter %s), so the response is activity not digestion. Logged, but not used for meal-impact.', COALESCE(nm,'meal'), round(pre_hr), round(pre_var,1));
  ELSE verdict := 'clean';
    note := format('%s (~%sg net carbs): rested at HR %s, rose to %s after (adj +%s bpm). %s', COALESCE(nm,'meal'), round(gl), round(pre_hr), round(post_mean), round(adj_bump,1),
      CASE WHEN adj_bump >= 8 THEN 'A real post-meal bump.' WHEN adj_bump >= 3 THEN 'A mild bump.' ELSE 'Barely moved your HR.' END);
  END IF;
  RETURN jsonb_build_object('verdict',verdict,'meal',nm,'carbs_g',carbs,'net_carbs_g',gl,'kcal',kcal,'is_alcohol',alc,
    'pre_hr',round(pre_hr,1),'pre_var',round(pre_var,1),'post_mean',round(post_mean,1),'post_peak',post_peak,
    'raw_bump_bpm',round(raw_bump,1),'circ_drift_bpm',round(circ_drift,1),'adj_bump_bpm',round(adj_bump,1),'note',note);
END;$f$;
COMMENT ON FUNCTION public.meal_hr_response IS 'v126: circadian-detrended post-prandial HR from realtime_health. Rest-gated (clean vs active_unreliable). HR as a relative glucose stand-in, experimental.';

CREATE OR REPLACE FUNCTION public.log_meal_text(p_user_id uuid, p_text text, p_when timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE est jsonb; new_id uuid; items_out jsonb;
BEGIN
  est := public.estimate_meal_from_text(p_text);
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'name', it->>'name', 'carbs_g', (it->>'net_carbs_g')::numeric, 'fiber_g', 0,
      'kcal', (it->>'kcal')::int, 'is_alcohol', (it->>'is_alcohol')::boolean, 'gi_band', it->>'gi_band')), '[]'::jsonb)
    INTO items_out FROM jsonb_array_elements(est->'items') it;
  INSERT INTO public.food_entries (user_id, captured_at, items, caption, total_kcal, source, confidence, created_at)
  VALUES (p_user_id, p_when, items_out, p_text, (est->>'kcal')::int, 'text', est->>'confidence', now())
  RETURNING id INTO new_id;
  RETURN jsonb_build_object('id', new_id, 'logged_at', p_when, 'estimate', est);
END;$f$;
COMMENT ON FUNCTION public.log_meal_text IS 'v126: text -> estimate -> insert food_entry (source=text). The RPC the public app calls so meal logic stays server-side.';

CREATE OR REPLACE FUNCTION public.meal_impact_ranking(p_user_id uuid, p_days int DEFAULT 90)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $f$
DECLARE rows jsonb; n_clean int;
BEGIN
  WITH meals AS (
    SELECT id, COALESCE(caption, items->0->>'name') nm, public.meal_hr_response(p_user_id, id) resp
    FROM food_entries WHERE user_id=p_user_id AND captured_at >= now() - make_interval(days => p_days)),
  clean AS (
    SELECT nm, (resp->>'net_carbs_g')::numeric carbs, (resp->>'adj_bump_bpm')::numeric bump
    FROM meals WHERE resp->>'verdict' = 'clean')
  SELECT jsonb_agg(jsonb_build_object('meal',nm,'net_carbs_g',carbs,'adj_bump_bpm',bump) ORDER BY bump DESC), count(*)
    INTO rows, n_clean FROM clean;
  RETURN jsonb_build_object('clean_meals', COALESCE(n_clean,0), 'ranking', COALESCE(rows,'[]'::jsonb),
    'note', CASE WHEN COALESCE(n_clean,0) < 3
      THEN format('Only %s clean readings so far. Log a few meals while resting (not after a ride) and this sharpens up.', COALESCE(n_clean,0))
      ELSE 'Ranked by circadian-adjusted HR bump: top of the list hits your system hardest.' END);
END;$f$;
COMMENT ON FUNCTION public.meal_impact_ranking IS 'v126: ranks clean meal_hr_response readings by adjusted HR bump. Honest about low sample count.';
