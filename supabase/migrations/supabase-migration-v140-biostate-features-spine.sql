-- ════════════════════════════════════════════════════════════════════════════
--  v140 — Biostate feature SPINE: biostate_features_now()
--  The shared HRV math every detector reads. On-demand (no cron, no table) —
--  realtime_health is already dense (~290 rows/hr).
--
--  WHY Lomb-Scargle (not resample+FFT): rr_intervals land in ~6-beat chunks with
--  wall-clock gaps. Interpolating onto a 4 Hz grid across gaps fabricates signal.
--  Lomb-Scargle is the standard periodogram for UNEVENLY-sampled series — it uses
--  the real beat times, no interpolation. N~150 beats x ~85 freq bins = trivial in PG.
--
--  Time axis = cumulative-RR (cardiac time), the canonical HRV tachogram axis.
--  Returns ONE jsonb feature vector: time-domain + frequency-domain + respiration
--  + HR-corrected variants + a quality block. Detectors stay thin.
--
--  Params (bands, window) come from biostate_config; sensible fallbacks if absent.
-- ════════════════════════════════════════════════════════════════════════════

-- drop the earlier 2-arg overload so biostate_features_now() isn't ambiguous
DROP FUNCTION IF EXISTS public.biostate_features_now(uuid, int);

CREATE OR REPLACE FUNCTION public.biostate_features_now(
  p_user     uuid        DEFAULT '372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid,
  p_window_s int         DEFAULT 240,
  p_end      timestamptz DEFAULT now()   -- anchor end (for replay/testing); default = live
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result jsonb;
BEGIN
  WITH
  -- ── rows in window (only those carrying RR) ──
  win AS (
    SELECT row_number() OVER (ORDER BY recorded_at) AS rid,
           recorded_at, rr_intervals, dfa_alpha1, accel_mag_mg, respiratory_rate, sleep_stage
    FROM realtime_health
    WHERE user_id = p_user
      AND recorded_at >  p_end - make_interval(secs => p_window_s)
      AND recorded_at <= p_end
      AND rr_intervals IS NOT NULL
      AND array_length(rr_intervals, 1) > 0
    ORDER BY recorded_at
  ),
  span AS (
    SELECT EXTRACT(EPOCH FROM (max(recorded_at) - min(recorded_at)))::numeric AS wall_s,
           max(dfa_alpha1)            AS dfa_latest,
           avg(accel_mag_mg)::numeric AS accel_avg,
           avg(respiratory_rate)::numeric AS strap_resp,   -- Whoop native RR (validated in SLEEP)
           mode() WITHIN GROUP (ORDER BY sleep_stage) AS sleep_stage
    FROM win
  ),
  w0 AS (SELECT min(recorded_at) AS t0 FROM win),
  -- ── flatten RR, reconstructing REAL wall-clock beat times per row ──
  -- A row's RR chunk ends at recorded_at; back-walk by the remaining RR in the row.
  -- Real times keep inter-chunk gaps intact → Lomb-Scargle reads true Hz (no compression).
  beats0 AS (
    SELECT w.rid, w.recorded_at AS r_at, b.rr::numeric AS rr_ms, b.ord,
           sum(b.rr::numeric) OVER (PARTITION BY w.rid ORDER BY b.ord) AS cum_in_row,
           sum(b.rr::numeric) OVER (PARTITION BY w.rid)                AS row_sum
    FROM win w, unnest(w.rr_intervals) WITH ORDINALITY AS b(rr, ord)
  ),
  total_beats AS (SELECT count(*) AS n0 FROM beats0),
  -- absolute physiologic gate (30–200 bpm)
  phys AS (SELECT * FROM beats0 WHERE rr_ms BETWEEN 300 AND 2000),
  med  AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY rr_ms) AS m FROM phys),
  -- relative ectopic gate: drop missed-/extra-beat artifacts (RR far from window
  -- median). This kills the 2× missed-beat spikes (~1800ms) that slip under the
  -- 2000ms ceiling and blow SDNN/RMSSD up to 200+.
  beats AS (
    SELECT row_number() OVER (ORDER BY p.r_at, p.ord) AS k, p.rr_ms,
           EXTRACT(EPOCH FROM (p.r_at - (SELECT t0 FROM w0)))::numeric
             - (p.row_sum - p.cum_in_row)/1000.0 AS t_s   -- real wall-clock time (s from window start)
    FROM phys p, med
    WHERE p.rr_ms BETWEEN med.m*0.6 AND med.m*1.7
  ),
  agg AS (SELECT count(*) AS n_beats, avg(rr_ms) AS mean_rr, stddev_samp(rr_ms) AS sdnn FROM beats),
  -- ── successive differences → RMSSD, pNN50, SD1 ──
  -- successive differences, BUT only between truly-adjacent beats. A pair whose
  -- wall-clock gap exceeds ~1.5× its RR means missing beats sit between them →
  -- that diff is an artifact (this is what blew RMSSD up to 245ms). Drop it.
  diffs AS (
    SELECT rr_ms - lag(rr_ms) OVER (ORDER BY k) AS d,
           t_s   - lag(t_s)   OVER (ORDER BY k) AS dt,
           rr_ms AS rr_now
    FROM beats
  ),
  td AS (
    SELECT sqrt(avg(d*d))                                  AS rmssd,
           100.0*avg(CASE WHEN abs(d) > 50 THEN 1 ELSE 0 END) AS pnn50,
           coalesce(stddev_samp(d),0)/sqrt(2)              AS sd1
    FROM diffs
    WHERE d IS NOT NULL AND dt <= rr_now/1000.0 * 1.5
  ),
  -- ── frequency grid 0.03–0.45 Hz @ 0.005 Hz ──
  freqs AS (SELECT generate_series(0.030, 0.450, 0.005)::numeric AS f),
  gridspec AS (SELECT max(t_s) AS tmax, avg(rr_ms) AS my, count(*) AS nb FROM beats),
  -- even 4 Hz time grid spanning the window
  grid AS (
    SELECT g*0.25::numeric AS tg
    FROM generate_series(0, GREATEST((SELECT floor(tmax/0.25)::int FROM gridspec), 0)) g
  ),
  -- linear-interpolate the RR tachogram onto the even grid. Bridging gaps with a
  -- straight line is the research recipe (resample to 4 Hz) and gives a STABLE
  -- spectrum — vs Lomb-Scargle on raw gappy beats which aliased resp between 8 & 21.
  interp AS (
    SELECT gr.tg,
           (lo.rr_ms + (hi.rr_ms - lo.rr_ms) * (gr.tg - lo.t_s)/NULLIF(hi.t_s - lo.t_s, 0)) AS y
    FROM grid gr
    CROSS JOIN LATERAL (SELECT rr_ms, t_s FROM beats WHERE t_s <= gr.tg ORDER BY t_s DESC LIMIT 1) lo
    CROSS JOIN LATERAL (SELECT rr_ms, t_s FROM beats WHERE t_s >= gr.tg ORDER BY t_s ASC  LIMIT 1) hi
  ),
  -- periodogram on the detrended even-grid series (powers relative → ratios/peak only)
  pxx AS (
    SELECT f.f,
           ( power(sum((i.y - gs.my)*cos(2*pi()*f.f*i.tg)), 2)
           + power(sum((i.y - gs.my)*sin(2*pi()*f.f*i.tg)), 2) ) AS power
    FROM freqs f CROSS JOIN interp i CROSS JOIN gridspec gs
    WHERE i.y IS NOT NULL
    GROUP BY f.f
  ),
  -- 3-bin moving-average smooth (research: smoothing stabilizes the spectral peak;
  -- a raw periodogram argmax flips between adjacent bins on tiny input changes)
  pxx_s AS (
    SELECT f, avg(power) OVER (ORDER BY f ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS power
    FROM pxx
  ),
  bands AS (
    SELECT
      coalesce(sum(power) FILTER (WHERE f >= 0.04 AND f < 0.15),0) * 0.005 AS lf,
      coalesce(sum(power) FILTER (WHERE f >= 0.15 AND f < 0.40),0) * 0.005 AS hf,
      coalesce(sum(power) FILTER (WHERE f >= 0.04 AND f < 0.40),0) * 0.005 AS total
    FROM pxx_s
  ),
  -- ── respiration = dominant (smoothed) peak in 0.12–0.40 Hz (7.2–24 bpm) ──
  resp AS (
    SELECT f AS rf FROM pxx_s WHERE f >= 0.12 AND f < 0.40 ORDER BY power DESC LIMIT 1
  ),
  -- ── current_state extras (baselines, activity, baevsky) ──
  cs AS (
    SELECT current_activity_state, baseline_hrv_avg, baseline_resting_hr,
           current_baevsky_stress, current_hmm_state_id
    FROM current_state WHERE user_id = p_user LIMIT 1
  )
  SELECT jsonb_build_object(
    'ts', now(),
    'window_s', p_window_s,
    'mean_hr',  round((60000.0/NULLIF(agg.mean_rr,0))::numeric, 1),
    'mean_rr',  round((agg.mean_rr)::numeric, 1),
    'rmssd',    round((td.rmssd)::numeric, 2),
    'sdnn',     round((agg.sdnn)::numeric, 2),
    'pnn50',    round((td.pnn50)::numeric, 1),
    'sd1',      round((td.sd1)::numeric, 2),
    'sd2',      round((sqrt(GREATEST(2*power(agg.sdnn,2) - power(td.sd1,2), 0)))::numeric, 2),
    'lf',       round((bands.lf)::numeric, 1),
    'hf',       round((bands.hf)::numeric, 1),
    'total_power', round((bands.total)::numeric, 1),
    'lf_hf',    round((bands.lf / NULLIF(bands.hf,0))::numeric, 3),
    -- HR-corrected LF/HF (research [S4]: divide HRV feature by mean HR → +26.8% repeatability)
    'lf_hf_hrc', round(((bands.lf / NULLIF(bands.hf,0)) / NULLIF(60000.0/NULLIF(agg.mean_rr,0),0) * 60)::numeric, 4),
    'rmssd_hrc', round((td.rmssd / NULLIF(60000.0/NULLIF(agg.mean_rr,0),0) * 60)::numeric, 3),
    'resp_rate', round(((SELECT rf FROM resp) * 60)::numeric, 1),   -- RR-derived: low confidence at rest (undersampled)
    'resp_method', 'periodogram_4hz',
    'strap_resp', round((span.strap_resp)::numeric, 1),             -- Whoop native: trust this in SLEEP
    'sleep_stage', span.sleep_stage,
    'dfa_alpha1', round((span.dfa_latest)::numeric, 3),
    'baevsky_si', (SELECT round((current_baevsky_stress)::numeric,1) FROM cs),
    'activity_state', (SELECT current_activity_state FROM cs),
    'hmm_state_id', (SELECT current_hmm_state_id FROM cs),
    'baseline_rmssd', (SELECT baseline_hrv_avg FROM cs),
    'baseline_hr', (SELECT baseline_resting_hr FROM cs),
    'motion_flag', (span.accel_avg > 40),     -- ~movement threshold in mg
    'quality', jsonb_build_object(
       'n_beats', agg.n_beats,
       'n_raw', (SELECT n0 FROM total_beats),
       'ectopic_frac', round((1 - agg.n_beats::numeric / NULLIF((SELECT n0 FROM total_beats),0))::numeric, 3),
       'wall_s', round((span.wall_s)::numeric, 0),
       'coverage_frac', round((LEAST(agg.mean_rr * agg.n_beats / 1000.0 / NULLIF(p_window_s,0), 1))::numeric, 3),
       'spectral_ok', (agg.n_beats >= 80 AND (agg.mean_rr * agg.n_beats / 1000.0 / NULLIF(p_window_s,0)) >= 0.45),
       'score', round((
          LEAST(agg.n_beats::numeric/120, 1) * 0.5
          + LEAST(agg.mean_rr * agg.n_beats / 1000.0 / NULLIF(p_window_s,0), 1) * 0.3
          + GREATEST(1 - (1 - agg.n_beats::numeric / NULLIF((SELECT n0 FROM total_beats),0)) / 0.3, 0) * 0.2
       )::numeric, 2)
    )
  )
  INTO result
  FROM agg, td, bands, span;

  RETURN coalesce(result, jsonb_build_object('error','no_data','window_s',p_window_s));
END;
$$;

GRANT EXECUTE ON FUNCTION public.biostate_features_now(uuid, int, timestamptz) TO anon, authenticated, service_role;
