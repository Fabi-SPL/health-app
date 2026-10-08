-- v202: the Strain tab's 15-minute heart-rate averages in one call.
-- The app fetched every raw 1 Hz row of the day (up to ~80k rows, one request per 15-minute slice)
-- only to average them. Same buckets as StrainDayAPI.sliceAverage: aligned to 900 s epochs,
-- [from, to), 30 < hr <= 220. STABLE so PostgREST serves it over GET.
CREATE OR REPLACE FUNCTION public.strain_hr_slices(p_from timestamptz, p_to timestamptz)
RETURNS TABLE(at timestamptz, bpm double precision)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT to_timestamp(floor(extract(epoch FROM r.recorded_at) / 900) * 900) AS at,
         avg(r.heart_rate)::double precision AS bpm
    FROM realtime_health r
   WHERE r.user_id = auth.uid()
     AND r.recorded_at >= p_from AND r.recorded_at < p_to
     AND r.heart_rate > 30 AND r.heart_rate <= 220
   GROUP BY 1
   ORDER BY 1;
$$;

GRANT EXECUTE ON FUNCTION public.strain_hr_slices(timestamptz, timestamptz) TO authenticated;
