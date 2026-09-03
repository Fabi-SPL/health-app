-- v156 — "Left today": the number that gives food logging a reason to exist.
-- Logging died 2026-07-12 because nothing ever answered "was that meal fine?".
-- TDEE is already real here (Whoop strain via body_daily_calories, v134), so the
-- only missing half was intake. This closes the loop server-side; the app renders.

ALTER TABLE public.user_body_profile
  ADD COLUMN IF NOT EXISTS cut_deficit_kcal integer,
  ADD COLUMN IF NOT EXISTS protein_target_g integer;

-- Aug 2026 cut: -600/day off a ~2200 TDEE, protein ~2 g/kg to hold lean mass.
UPDATE public.user_body_profile
   SET cut_deficit_kcal = COALESCE(cut_deficit_kcal, 600),
       protein_target_g = COALESCE(protein_target_g, 150)
 WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff';

CREATE OR REPLACE FUNCTION public.cut_status(
  p_user_id uuid,
  p_date date DEFAULT (now() AT TIME ZONE 'Europe/Berlin')::date)
RETURNS TABLE(
  tdee integer, bmr integer, active_kcal integer,
  deficit_target integer, target_intake integer,
  consumed integer, remaining integer,
  protein_g numeric, protein_target integer,
  n_meals integer, last_meal_at timestamptz, headline text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE
  c record; p record; f record; v_active int;
BEGIN
  SELECT * INTO c FROM body_daily_calories(p_user_id, p_date);
  SELECT COALESCE(cut_deficit_kcal, 0) AS def, COALESCE(protein_target_g, 0) AS prot
    INTO p FROM user_body_profile WHERE user_id = p_user_id;

  -- body_daily_calories only knows strain accrued SO FAR. Using it raw mid-morning
  -- yields a near-BMR TDEE and an absurdly low target. Project the rest of the day
  -- from the trailing 7-day active average, ratcheting up if today already beat it.
  IF p_date = (now() AT TIME ZONE 'Europe/Berlin')::date THEN
    SELECT GREATEST(c.active_kcal, COALESCE(round(avg(x.active_kcal)), 0))
      INTO v_active
      FROM generate_series(p_date - 7, p_date - 1, '1 day') d
      CROSS JOIN LATERAL body_daily_calories(p_user_id, d::date) x;
  ELSE
    v_active := c.active_kcal;
  END IF;

  -- kcal lives on the entry, protein lives inside items — summing both across one
  -- lateral join fans the entry total out once per item (215 kcal became 645).
  SELECT COALESCE((SELECT sum(total_kcal) FROM food_entries
                    WHERE user_id = p_user_id
                      AND (captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date), 0)::int AS kcal,
         COALESCE((SELECT sum((i->>'protein_g')::numeric)
                     FROM food_entries fe, jsonb_array_elements(fe.items) i
                    WHERE fe.user_id = p_user_id
                      AND (fe.captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date), 0) AS prot,
         COALESCE((SELECT count(*) FROM food_entries
                    WHERE user_id = p_user_id
                      AND (captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date), 0)::int AS n,
         (SELECT max(captured_at) FROM food_entries
           WHERE user_id = p_user_id
             AND (captured_at AT TIME ZONE 'Europe/Berlin')::date = p_date) AS last_at
    INTO f;

  bmr := c.bmr;
  active_kcal := v_active;
  tdee := c.bmr + v_active;
  deficit_target := p.def;
  target_intake  := GREATEST(tdee - p.def, 1200);   -- never coach below 1200
  consumed       := f.kcal;
  remaining      := target_intake - f.kcal;
  protein_g      := round(f.prot, 1);
  protein_target := p.prot;
  n_meals        := f.n;
  last_meal_at   := f.last_at;

  headline := CASE
    WHEN n_meals = 0            THEN 'Nothing logged yet'
    WHEN remaining < -300       THEN 'Over by ' || abs(remaining) || ' — tomorrow resets it'
    WHEN remaining < 0          THEN 'Just over, ' || abs(remaining) || ' — that is noise'
    WHEN remaining < 250        THEN remaining || ' left — basically done'
    ELSE                             remaining || ' left today'
  END;

  RETURN NEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cut_status(uuid, date) TO authenticated, service_role;
