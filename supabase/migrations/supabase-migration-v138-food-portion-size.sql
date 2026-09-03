-- v138: food portion size (relative, personalized)
-- One-tap subjective portion size per food entry. Scales quick-log baselines and
-- feeds Hermes a dose dimension. "Normal" is interpreted against Fabi's own gram
-- history per food + body weight (user_body_profile: 76kg / 178cm / male / maintain).
ALTER TABLE public.food_entries
  ADD COLUMN IF NOT EXISTS portion_size   text,                  -- tiny|small|normal|big|huge
  ADD COLUMN IF NOT EXISTS portion_factor numeric DEFAULT 1.0;   -- multiplier vs baseline

COMMENT ON COLUMN public.food_entries.portion_size   IS 'Subjective relative portion: tiny|small|normal|big|huge';
COMMENT ON COLUMN public.food_entries.portion_factor IS 'Portion multiplier vs baseline (tiny .5 / small .75 / normal 1 / big 1.5 / huge 2)';
