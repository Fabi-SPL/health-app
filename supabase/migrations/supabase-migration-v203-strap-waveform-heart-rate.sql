-- v203: heart rate from the strap's stored pulse waveform.
--
-- Since at least 2026-09-21 the strap stores no per-second heart-rate records (v24) at all. It stores
-- v25 records instead: one per 0.96 s, 24 samples of the optical pulse waveform at 25 Hz plus gravity.
-- The app counted them as heart rate 1-7 and threw them away, so every night it was not connected for
-- came back empty although the strap had recorded it. On 2026-10-09, 41 of the 42 sampled windows
-- where live heart rate existed for the same minute agreed with it: median 0.9 bpm apart, 77% within
-- 5 bpm (20 s windows, autocorrelation >= 0.6).
--
-- The app (v117) uploads the raw records here; this derives one heart-rate row per record into
-- realtime_health as source 'whoop_v25_ppg', skipping minutes that live or backfilled rows already cover.

CREATE EXTENSION IF NOT EXISTS plv8;

CREATE TABLE IF NOT EXISTS public.whoop_hist_raw (
  user_id    uuid        NOT NULL,
  unix       bigint      NOT NULL,
  subsec     integer     NOT NULL,
  ver        smallint    NOT NULL,
  hex        text        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  hr_done    boolean     NOT NULL DEFAULT false,
  PRIMARY KEY (user_id, unix, subsec)
);
CREATE INDEX IF NOT EXISTS whoop_hist_raw_todo ON public.whoop_hist_raw (user_id, unix) WHERE NOT hr_done;

ALTER TABLE public.whoop_hist_raw ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own hist raw insert" ON public.whoop_hist_raw;
CREATE POLICY "own hist raw insert" ON public.whoop_hist_raw FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "own hist raw read" ON public.whoop_hist_raw;
CREATE POLICY "own hist raw read" ON public.whoop_hist_raw FOR SELECT USING (auth.uid() = user_id);
GRANT SELECT, INSERT ON public.whoop_hist_raw TO authenticated;

CREATE OR REPLACE FUNCTION public.derive_hr_from_hist_raw(p_user uuid, p_budget_ms integer DEFAULT 20000)
RETURNS integer
LANGUAGE plv8
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  const FS = 25, WIN = 500, STEP = 125, MIN_AC = 0.6, CHUNK = 6 * 3600, PAD = 40;
  const started = Date.now();
  let inserted = 0;

  const decode = hex => {
    const x = new Array(24);
    for (let k = 0; k < 24; k++) {
      const p = 32 + k * 4;
      let v = parseInt(hex.substr(p, 2), 16) | (parseInt(hex.substr(p + 2, 2), 16) << 8);
      if (v >= 32768) v -= 65536;
      x[k] = v;
    }
    return x;
  };

  while (Date.now() - started < p_budget_ms) {
    const todo = plv8.execute(
      "SELECT min(unix)::float8 AS lo, max(unix)::float8 AS hi FROM whoop_hist_raw WHERE user_id = $1 AND NOT hr_done AND ver = 25",
      [p_user])[0];
    if (!todo || todo.lo === null) break;
    const lo = todo.lo, hi = Math.min(todo.hi, todo.lo + CHUNK);

    const rows = plv8.execute(
      "SELECT unix::float8 AS u, subsec, hex FROM whoop_hist_raw WHERE user_id = $1 AND ver = 25 AND unix BETWEEN $2 AND $3 ORDER BY unix, subsec",
      [p_user, lo - PAD, hi + PAD]);
    const recs = rows.filter(r => r.hex.length >= 128).map(r => ({ t: r.u + r.subsec / 32768, x: decode(r.hex) }));

    const covered = new Set(plv8.execute(
      "SELECT extract(epoch FROM date_trunc('minute', recorded_at))::float8 AS m FROM realtime_health " +
      "WHERE user_id = $1 AND recorded_at BETWEEN to_timestamp($2) AND to_timestamp($3) AND source <> 'whoop_v25_ppg' " +
      "GROUP BY 1 HAVING count(*) >= 20", [p_user, lo - PAD, hi + PAD]).map(r => r.m));

    const segs = [];
    let cur = [];
    for (const r of recs) {
      if (cur.length) {
        const d = r.t - cur[cur.length - 1].t;
        if (!(d > 0.9 && d < 1.02)) { segs.push(cur); cur = []; }
      }
      cur.push(r);
    }
    if (cur.length) segs.push(cur);

    const outT = [], outHR = [];
    for (const seg of segs) {
      if (seg.length < 21) continue;
      const x = [];
      for (const r of seg) for (const v of r.x) x.push(v);
      const n = x.length, pre = new Float64Array(n + 1), y = new Float64Array(n);
      for (let i = 0; i < n; i++) pre[i + 1] = pre[i] + x[i];
      for (let i = 0; i < n; i++) {
        const a = Math.max(0, i - 25), b = Math.min(n, i + 25);
        y[i] = x[i] - (pre[b] - pre[a]) / (b - a);
      }
      const sampleTime = i => seg[Math.floor(i / 24)].t + (i % 24) / FS;

      const wins = [];
      for (let st = 0; st + WIN <= n; st += STEP) {
        let s0 = 0;
        for (let i = st; i < st + WIN; i++) s0 += y[i] * y[i];
        if (s0 <= 0) continue;
        const A = [];
        for (let L = 7; L <= 38; L++) {
          let s = 0;
          for (let i = st; i + L < st + WIN; i++) s += y[i] * y[i + L];
          A[L] = s / s0 * WIN / (WIN - L);
        }
        let best = 8;
        for (let L = 8; L <= 37; L++) if (A[L] > A[best]) best = L;
        if (A[best] < MIN_AC) continue;
        const den = A[best - 1] - 2 * A[best] + A[best + 1];
        const d = den !== 0 ? (A[best - 1] - A[best + 1]) / (2 * den) : 0;
        const hr = 60 * FS / (best + Math.max(-0.5, Math.min(0.5, d)));
        if (hr < 35 || hr > 200) continue;
        wins.push({ t: sampleTime(st + WIN / 2), hr });
      }
      if (wins.length < 2) continue;

      for (const r of seg) {
        if (r.t < lo - PAD / 2 || r.t > hi + PAD / 2) continue;
        if (covered.has(Math.floor(r.t / 60) * 60)) continue;
        const c = r.t + 0.48;
        const near = wins.filter(w => Math.abs(w.t - c) <= 12.5).map(w => w.hr).sort((a, b) => a - b);
        if (near.length < 2) continue;
        outT.push(r.t);
        outHR.push(Math.round(near[near.length >> 1]));
      }
    }

    plv8.execute(
      "DELETE FROM realtime_health WHERE user_id = $1 AND source = 'whoop_v25_ppg' AND recorded_at BETWEEN to_timestamp($2) AND to_timestamp($3)",
      [p_user, lo - PAD / 2, hi + PAD / 2]);
    if (outT.length) {
      plv8.execute(
        "INSERT INTO realtime_health (user_id, recorded_at, heart_rate, source) " +
        "SELECT $1, to_timestamp(u.t), u.hr, 'whoop_v25_ppg' FROM unnest($2::float8[], $3::int[]) AS u(t, hr)",
        [p_user, outT, outHR]);
      inserted += outT.length;
    }
    plv8.execute(
      "UPDATE whoop_hist_raw SET hr_done = true WHERE user_id = $1 AND NOT hr_done AND unix BETWEEN $2 AND $3",
      [p_user, lo, hi]);
    const msg = "from=" + lo + " to=" + hi + " records=" + recs.length + " segments=" + segs.length + " rows=" + outT.length;
    plv8.execute(
      "INSERT INTO bridge_logs (user_id, source, category, key, value, content) VALUES ($1, 'server', 'waveform_hr_derived', 'waveform_hr_derived', $2, $3)",
      [p_user, msg, '[SERVER] waveform_hr_derived: ' + msg]);
  }

  plv8.execute(
    "DELETE FROM whoop_hist_raw WHERE user_id = $1 AND hr_done AND created_at < now() - interval '30 days'", [p_user]);
  return inserted;
$function$;

-- Nights that gain waveform heart rate are recomputed like backfilled ones.
CREATE OR REPLACE FUNCTION public.recompute_backfilled_nights(p_user_id uuid, p_days integer DEFAULT 14)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  d date; n_rows int; n_recent int; prev int; done int := 0;
  w_from timestamptz; w_to timestamptz; msg text;
BEGIN
  FOR d IN SELECT generate_series(((now() AT TIME ZONE 'Europe/Berlin')::date - p_days),
                                  (now() AT TIME ZONE 'Europe/Berlin')::date, interval '1 day')::date
  LOOP
    -- the night that ends on d: 18:00 the evening before to 14:00 that day, Berlin time
    w_from := ((d - 1)::timestamp + interval '18 hours') AT TIME ZONE 'Europe/Berlin';
    w_to   := (d::timestamp + interval '14 hours') AT TIME ZONE 'Europe/Berlin';
    SELECT count(*), count(*) FILTER (WHERE created_at > now() - interval '10 minutes')
      INTO n_rows, n_recent
      FROM realtime_health
     WHERE user_id = p_user_id AND source IN ('whoop_ble_backfill', 'whoop_ble_history', 'whoop_v25_ppg')
       AND recorded_at >= w_from AND recorded_at < w_to;
    CONTINUE WHEN n_rows = 0 OR n_recent > 0;   -- nothing late, or still downloading
    SELECT backfill_rows INTO prev FROM night_backfill_marks WHERE user_id = p_user_id AND metric_date = d;
    CONTINUE WHEN prev IS NOT NULL AND n_rows < prev + 60;   -- under a minute or so of new data
    PERFORM recompute_health_metrics(p_user_id, d);
    INSERT INTO night_backfill_marks (user_id, metric_date, backfill_rows, recomputed_at)
    VALUES (p_user_id, d, n_rows, now())
    ON CONFLICT (user_id, metric_date) DO UPDATE SET backfill_rows = EXCLUDED.backfill_rows, recomputed_at = now();
    msg := 'date=' || d || ' backfill_rows=' || n_rows || ' prev=' || COALESCE(prev, 0);
    INSERT INTO bridge_logs (user_id, source, category, key, value, content)
    VALUES (p_user_id, 'server', 'night_backfill_recompute', 'night_backfill_recompute', msg,
            '[SERVER] night_backfill_recompute: ' || msg);
    done := done + 1;
  END LOOP;
  RETURN done;
END;
$function$;

SELECT cron.unschedule('derive_hr_from_hist_raw') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'derive_hr_from_hist_raw');
SELECT cron.schedule('derive_hr_from_hist_raw', '*/10 * * * *',
  $$SELECT public.derive_hr_from_hist_raw('372210e5-1dda-41b3-b759-5ff72293b8ff'::uuid)$$);
