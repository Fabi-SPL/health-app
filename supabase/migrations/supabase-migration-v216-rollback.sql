-- v216 rollback: drop the night review view and the generated night_data column.
DROP VIEW IF EXISTS public.night_review;
ALTER TABLE public.health_metrics DROP COLUMN IF EXISTS night_data;
