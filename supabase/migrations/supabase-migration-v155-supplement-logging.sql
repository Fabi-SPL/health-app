-- v155 — Supplement logging: shelf + discrete dose events.
-- Supplements are NOT food. The June ginger-shot experiment lost its signal because
-- the shot went into food_entries as a ~27 kcal item with no discrete timestamp.
-- This gives supplements their own home so Hermes/correlations can treat them as
-- their own variable instead of noise inside the calorie stream.

-- ---------------------------------------------------------------- shelf
CREATE TABLE IF NOT EXISTS public.supplement_products (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL,
  barcode       text,                    -- EAN/UPC when the scan resolved
  name          text NOT NULL,
  brand         text,
  form          text,                    -- capsule | tablet | powder | liquid | shot
  serving_unit  text NOT NULL DEFAULT 'capsule',
  serving_size  numeric DEFAULT 1,       -- how many units the LABEL calls one serving
  -- Per-SERVING actives, e.g. {"vitamin_d3_iu":5000,"magnesium_mg":300}.
  -- Free-form on purpose: labels vary wildly and Gemini fills this from a photo.
  actives       jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- What Fabi should actually take, once a personalised regimen is set. Same shape
  -- as actives but expressed in servings/day; NULL = no regimen decided yet.
  target_daily  numeric,
  source        text NOT NULL DEFAULT 'manual',   -- barcode | label_photo | manual
  raw_label     jsonb,                   -- untouched OFF payload or Gemini extraction
  active        boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS supplement_products_user_barcode_uidx
  ON public.supplement_products(user_id, barcode) WHERE barcode IS NOT NULL;
CREATE INDEX IF NOT EXISTS supplement_products_user_active_idx
  ON public.supplement_products(user_id, active);

-- ---------------------------------------------------------------- dose events
CREATE TABLE IF NOT EXISTS public.supplement_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL,
  product_id  uuid REFERENCES public.supplement_products(id) ON DELETE SET NULL,
  -- Denormalised so a deleted product never orphans the history.
  name        text NOT NULL,
  servings    numeric NOT NULL DEFAULT 1,
  actives     jsonb NOT NULL DEFAULT '{}'::jsonb,   -- servings * product actives, frozen at log time
  taken_at    timestamptz NOT NULL DEFAULT now(),
  source      text NOT NULL DEFAULT 'tap',          -- tap | shelf | voice | auto
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS supplement_log_user_taken_idx
  ON public.supplement_log(user_id, taken_at DESC);
CREATE INDEX IF NOT EXISTS supplement_log_product_idx
  ON public.supplement_log(product_id);

ALTER TABLE public.supplement_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplement_log      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS supplement_products_own ON public.supplement_products;
CREATE POLICY supplement_products_own ON public.supplement_products
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS supplement_log_own ON public.supplement_log;
CREATE POLICY supplement_log_own ON public.supplement_log
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ---------------------------------------------------------------- upsert product
CREATE OR REPLACE FUNCTION public.upsert_supplement_product(
  p_user_id uuid, p_name text, p_barcode text DEFAULT NULL,
  p_brand text DEFAULT NULL, p_form text DEFAULT 'capsule',
  p_serving_unit text DEFAULT 'capsule', p_serving_size numeric DEFAULT 1,
  p_actives jsonb DEFAULT '{}'::jsonb, p_source text DEFAULT 'manual',
  p_raw_label jsonb DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE v_id uuid;
BEGIN
  -- Barcode is the natural key when we have one; otherwise always insert fresh.
  IF p_barcode IS NOT NULL THEN
    SELECT id INTO v_id FROM supplement_products
     WHERE user_id = p_user_id AND barcode = p_barcode;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO supplement_products(user_id, barcode, name, brand, form,
      serving_unit, serving_size, actives, source, raw_label)
    VALUES (p_user_id, p_barcode, p_name, p_brand, p_form,
      p_serving_unit, p_serving_size, p_actives, p_source, p_raw_label)
    RETURNING id INTO v_id;
  ELSE
    UPDATE supplement_products SET
      name = p_name, brand = COALESCE(p_brand, brand), form = p_form,
      serving_unit = p_serving_unit, serving_size = p_serving_size,
      -- Merge so a thin barcode hit never wipes a richer label-photo extraction.
      actives = actives || p_actives,
      raw_label = COALESCE(p_raw_label, raw_label),
      active = true, updated_at = now()
    WHERE id = v_id;
  END IF;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------- log a dose
CREATE OR REPLACE FUNCTION public.log_supplement(
  p_user_id uuid, p_product_id uuid DEFAULT NULL, p_name text DEFAULT NULL,
  p_servings numeric DEFAULT 1, p_taken_at timestamptz DEFAULT now(),
  p_source text DEFAULT 'tap', p_note text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
DECLARE v_name text; v_actives jsonb := '{}'::jsonb; v_id uuid;
BEGIN
  IF p_product_id IS NOT NULL THEN
    SELECT name, actives INTO v_name, v_actives
      FROM supplement_products WHERE id = p_product_id AND user_id = p_user_id;
  END IF;
  v_name := COALESCE(p_name, v_name);
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'log_supplement needs either a known product_id or a name';
  END IF;

  -- Freeze the dose at log time — if the bottle changes later, history stays true.
  SELECT COALESCE(jsonb_object_agg(k, round((val::numeric) * p_servings, 4)), '{}'::jsonb)
    INTO v_actives
    FROM jsonb_each_text(v_actives) AS t(k, val)
   WHERE val ~ '^[0-9]+(\.[0-9]+)?$';

  INSERT INTO supplement_log(user_id, product_id, name, servings, actives, taken_at, source, note)
  VALUES (p_user_id, p_product_id, v_name, p_servings, v_actives, p_taken_at, p_source, p_note)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------- shelf read
-- One row per product with today's dose count — everything the shelf UI needs.
CREATE OR REPLACE FUNCTION public.supplement_shelf(p_user_id uuid)
RETURNS TABLE(id uuid, name text, brand text, form text, serving_unit text,
              actives jsonb, target_daily numeric, taken_today numeric,
              last_taken timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
  SELECT p.id, p.name, p.brand, p.form, p.serving_unit, p.actives, p.target_daily,
         COALESCE((SELECT sum(l.servings) FROM supplement_log l
                    WHERE l.product_id = p.id
                      AND l.taken_at >= (now() AT TIME ZONE 'Europe/Berlin')::date), 0),
         (SELECT max(l.taken_at) FROM supplement_log l WHERE l.product_id = p.id)
    FROM supplement_products p
   WHERE p.user_id = p_user_id AND p.active
   ORDER BY p.name;
$$;

-- ---------------------------------------------------------------- daily rollup
-- Total actives per day, so a correlation lane can join supplements to recovery.
CREATE OR REPLACE FUNCTION public.supplement_daily_actives(
  p_user_id uuid, p_days int DEFAULT 30)
RETURNS TABLE(d date, actives jsonb, n_doses int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp' AS $$
  WITH x AS (
    SELECT (taken_at AT TIME ZONE 'Europe/Berlin')::date AS d, k, val::numeric AS v
      FROM supplement_log l, jsonb_each_text(l.actives) AS t(k, val)
     WHERE l.user_id = p_user_id
       AND l.taken_at >= now() - make_interval(days => p_days)
       AND val ~ '^[0-9]+(\.[0-9]+)?$'
  ), agg AS (
    SELECT d, jsonb_object_agg(k, s) AS actives FROM (
      SELECT d, k, sum(v) AS s FROM x GROUP BY d, k
    ) q GROUP BY d
  )
  SELECT a.d, a.actives,
         (SELECT count(*)::int FROM supplement_log l
           WHERE l.user_id = p_user_id
             AND (l.taken_at AT TIME ZONE 'Europe/Berlin')::date = a.d)
    FROM agg a ORDER BY a.d DESC;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_supplement_product(uuid,text,text,text,text,text,numeric,jsonb,text,jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.log_supplement(uuid,uuid,text,numeric,timestamptz,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.supplement_shelf(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.supplement_daily_actives(uuid,int) TO authenticated, service_role;
