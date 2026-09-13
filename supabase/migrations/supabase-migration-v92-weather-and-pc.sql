-- v92: Weather correlation + PC activity logging
--
-- Two parallel streams of personal context layered onto health_metrics:
--
-- 1. Weather: daily snapshot from Open-Meteo (Regensburg, location from
--    user_location). Lets us correlate temp/pressure/conditions with
--    next-morning HRV/RHR/sleep.
--
-- 2. PC activity: low-overhead bridge service running on Fabi's PC pushes:
--    - foreground-app sessions (psutil, ~30MB RAM, <0.5% CPU)
--    - system samples (CPU/RAM)
--    - HWiNFO shared-memory sensors (GPU/temps/fans/power) when available
--   All over HTTPS direct to Supabase. No third party.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. WEATHER DAILY
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS weather_daily (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users(id),
  date          date NOT NULL,
  latitude      numeric(7,4),
  longitude     numeric(7,4),

  -- Temperature
  temp_min_c    numeric(5,2),
  temp_max_c    numeric(5,2),
  temp_avg_c    numeric(5,2),
  feels_like_c  numeric(5,2),

  -- Atmosphere
  pressure_hpa  numeric(6,1),
  pressure_change_hpa numeric(5,1),  -- vs yesterday
  humidity_pct  numeric(4,1),
  wind_avg_kmh  numeric(4,1),
  wind_gust_kmh numeric(4,1),

  -- Conditions
  conditions_code int,           -- WMO weather code (Open-Meteo)
  conditions_label text,         -- 'overcast', 'rain', 'clear', etc.
  precipitation_mm numeric(5,2),
  cloud_cover_pct numeric(4,1),
  uv_index      numeric(3,1),

  -- Light
  sunrise       timestamptz,
  sunset        timestamptz,
  daylight_min  int,

  source        text DEFAULT 'open-meteo',
  created_at    timestamptz DEFAULT now(),
  UNIQUE(user_id, date)
);
CREATE INDEX IF NOT EXISTS idx_weather_daily_user_date ON weather_daily(user_id, date DESC);

COMMENT ON TABLE weather_daily IS 'Daily weather snapshot per user location. Joins with health_metrics.metric_date for correlation.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. PC APP CATEGORIES (lookup, user-editable)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS pc_app_categories (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users(id),
  app_pattern   text NOT NULL,        -- glob/regex match against exe name
  category      text NOT NULL,        -- 'game' / 'code' / 'browser' / 'comm' / 'creative' / 'idle'
  display_name  text,                 -- 'World of Tanks', 'VS Code'
  is_focus      boolean DEFAULT false,-- true = this app counts as deep_work signal
  created_at    timestamptz DEFAULT now(),
  UNIQUE(user_id, app_pattern)
);
CREATE INDEX IF NOT EXISTS idx_pc_app_cats_user ON pc_app_categories(user_id);

COMMENT ON TABLE pc_app_categories IS 'User-editable app→category mapping. Bridge service reads this to label sessions.';

-- Seed Fabi's defaults
INSERT INTO pc_app_categories (user_id, app_pattern, category, display_name, is_focus) VALUES
  ('YOUR_USER_ID_HERE', 'WorldOfTanks.exe', 'game', 'World of Tanks', false),
  ('YOUR_USER_ID_HERE', 'wot.exe', 'game', 'World of Tanks', false),
  ('YOUR_USER_ID_HERE', 'Code.exe', 'code', 'VS Code', true),
  ('YOUR_USER_ID_HERE', 'Cursor.exe', 'code', 'Cursor', true),
  ('YOUR_USER_ID_HERE', 'Claude.exe', 'code', 'Claude Code', true),
  ('YOUR_USER_ID_HERE', 'idea64.exe', 'code', 'IntelliJ', true),
  ('YOUR_USER_ID_HERE', 'chrome.exe', 'browser', 'Chrome', false),
  ('YOUR_USER_ID_HERE', 'firefox.exe', 'browser', 'Firefox', false),
  ('YOUR_USER_ID_HERE', 'msedge.exe', 'browser', 'Edge', false),
  ('YOUR_USER_ID_HERE', 'arc.exe', 'browser', 'Arc', false),
  ('YOUR_USER_ID_HERE', 'Discord.exe', 'comm', 'Discord', false),
  ('YOUR_USER_ID_HERE', 'Slack.exe', 'comm', 'Slack', false),
  ('YOUR_USER_ID_HERE', 'Teams.exe', 'comm', 'Teams', false),
  ('YOUR_USER_ID_HERE', 'Spotify.exe', 'media', 'Spotify', false),
  ('YOUR_USER_ID_HERE', 'Photoshop.exe', 'creative', 'Photoshop', true),
  ('YOUR_USER_ID_HERE', 'Blender.exe', 'creative', 'Blender', true),
  ('YOUR_USER_ID_HERE', 'Figma.exe', 'creative', 'Figma', true),
  ('YOUR_USER_ID_HERE', 'Notion.exe', 'work', 'Notion', false),
  ('YOUR_USER_ID_HERE', 'Obsidian.exe', 'work', 'Obsidian', true),
  ('YOUR_USER_ID_HERE', 'steam.exe', 'game', 'Steam', false)
ON CONFLICT (user_id, app_pattern) DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. PC ACTIVITY SESSIONS — one row per foreground-app session
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS pc_activity (
  id              bigserial PRIMARY KEY,
  user_id         uuid NOT NULL REFERENCES auth.users(id),
  started_at      timestamptz NOT NULL,
  ended_at        timestamptz,
  duration_sec    int,

  -- Identification
  exe             text NOT NULL,         -- 'WorldOfTanks.exe'
  app             text,                  -- friendly label from pc_app_categories
  window_title    text,                  -- '_truncated_'
  category        text,                  -- 'game' | 'code' | 'browser' | etc.
  is_focus        boolean DEFAULT false,

  -- Context aggregates (averages over the session)
  cpu_avg_pct     numeric(4,1),
  ram_avg_mb      int,
  gpu_avg_pct     numeric(4,1),
  gpu_temp_avg_c  numeric(4,1),
  cpu_temp_avg_c  numeric(4,1),
  power_draw_avg_w numeric(5,1),

  -- Health context (joined at insert time when strap is connected)
  hr_avg          numeric(4,1),
  hrv_avg         numeric(4,1),

  bridge_version  text,
  inserted_at     timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pc_activity_user_started ON pc_activity(user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_pc_activity_user_category ON pc_activity(user_id, category, started_at DESC);

COMMENT ON TABLE pc_activity IS 'Foreground app sessions from PC bridge. Closes on app switch, idle, or sleep.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. PC SYSTEM SAMPLES — periodic snapshots when active (every 60s by default)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS pc_system_samples (
  id            bigserial PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES auth.users(id),
  sampled_at    timestamptz NOT NULL DEFAULT now(),

  -- psutil basics (always present)
  cpu_pct       numeric(4,1),
  ram_pct       numeric(4,1),
  ram_used_mb   int,
  ram_total_mb  int,
  disk_read_mbps numeric(6,2),
  disk_write_mbps numeric(6,2),
  net_up_mbps    numeric(6,2),
  net_down_mbps  numeric(6,2),

  -- HWiNFO shared memory (nullable — only when HWiNFO is running)
  gpu_pct       numeric(4,1),
  gpu_temp_c    numeric(4,1),
  gpu_mem_pct   numeric(4,1),
  gpu_clock_mhz int,
  cpu_temp_c    numeric(4,1),
  cpu_clock_mhz int,
  fan_rpm_max   int,
  power_draw_w  numeric(5,1),

  active_exe    text,           -- snapshot of which app was foreground at sample
  is_idle       boolean DEFAULT false,
  inserted_at   timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pc_samples_user_time ON pc_system_samples(user_id, sampled_at DESC);

COMMENT ON TABLE pc_system_samples IS 'System-wide samples — CPU/RAM always, HWiNFO sensors when running. ~1440 rows/day at 60s cadence.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. CORRELATION FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Daily PC summary — categorized minutes per app per day
CREATE OR REPLACE FUNCTION pc_daily_summary(p_user_id uuid, p_date date DEFAULT current_date)
RETURNS TABLE (
  category text,
  app text,
  minutes int,
  sessions int,
  avg_hr numeric,
  avg_hrv numeric,
  avg_cpu_pct numeric,
  avg_gpu_pct numeric
) LANGUAGE sql STABLE AS $$
  SELECT
    COALESCE(category, 'uncategorized') as category,
    COALESCE(app, exe) as app,
    SUM(duration_sec)::int / 60 as minutes,
    COUNT(*)::int as sessions,
    AVG(hr_avg)::numeric(4,1) as avg_hr,
    AVG(hrv_avg)::numeric(4,1) as avg_hrv,
    AVG(cpu_avg_pct)::numeric(4,1) as avg_cpu_pct,
    AVG(gpu_avg_pct)::numeric(4,1) as avg_gpu_pct
  FROM pc_activity
  WHERE user_id = p_user_id
    AND started_at::date = p_date
    AND duration_sec >= 30  -- ignore <30s blips
  GROUP BY category, COALESCE(app, exe)
  ORDER BY minutes DESC;
$$;

COMMENT ON FUNCTION pc_daily_summary IS 'Per-day per-app rollup of PC activity with health context. Drives "Today on PC" tile.';

-- Weather × Health correlator (run nightly)
CREATE OR REPLACE FUNCTION compute_weather_correlations(p_user_id uuid, p_window_days int DEFAULT 60)
RETURNS TABLE (
  feature text,
  buckets text,
  hrv_delta_pct numeric,
  rhr_delta_bpm numeric,
  recovery_delta_pct numeric,
  n_days int
) LANGUAGE plpgsql STABLE AS $$
DECLARE
  baseline_hrv numeric;
  baseline_rhr numeric;
  baseline_rec numeric;
BEGIN
  SELECT
    percentile_cont(0.5) WITHIN GROUP (ORDER BY hrv_avg) FILTER (WHERE hrv_avg > 0),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY resting_hr) FILTER (WHERE resting_hr > 0),
    percentile_cont(0.5) WITHIN GROUP (ORDER BY recovery_score) FILTER (WHERE recovery_score > 0)
  INTO baseline_hrv, baseline_rhr, baseline_rec
  FROM health_metrics
  WHERE user_id = p_user_id AND metric_date >= current_date - p_window_days;

  -- Pressure drop
  RETURN QUERY
  SELECT 'pressure'::text, 'low (<1010 hPa)'::text,
    round(((avg(h.hrv_avg) - baseline_hrv) / NULLIF(baseline_hrv,0) * 100)::numeric, 1),
    round((avg(h.resting_hr) - baseline_rhr)::numeric, 1),
    round(((avg(h.recovery_score) - baseline_rec) / NULLIF(baseline_rec,0) * 100)::numeric, 1),
    count(*)::int
  FROM weather_daily w
  JOIN health_metrics h ON h.user_id = w.user_id AND h.metric_date = w.date + interval '1 day'
  WHERE w.user_id = p_user_id AND w.pressure_hpa < 1010
    AND h.hrv_avg > 0
  HAVING count(*) >= 3;

  -- Cold (<5°C)
  RETURN QUERY
  SELECT 'cold'::text, 'avg <5°C'::text,
    round(((avg(h.hrv_avg) - baseline_hrv) / NULLIF(baseline_hrv,0) * 100)::numeric, 1),
    round((avg(h.resting_hr) - baseline_rhr)::numeric, 1),
    round(((avg(h.recovery_score) - baseline_rec) / NULLIF(baseline_rec,0) * 100)::numeric, 1),
    count(*)::int
  FROM weather_daily w
  JOIN health_metrics h ON h.user_id = w.user_id AND h.metric_date = w.date + interval '1 day'
  WHERE w.user_id = p_user_id AND w.temp_avg_c < 5
    AND h.hrv_avg > 0
  HAVING count(*) >= 3;

  -- Short daylight (winter)
  RETURN QUERY
  SELECT 'short daylight'::text, '<10h'::text,
    round(((avg(h.hrv_avg) - baseline_hrv) / NULLIF(baseline_hrv,0) * 100)::numeric, 1),
    round((avg(h.resting_hr) - baseline_rhr)::numeric, 1),
    round(((avg(h.recovery_score) - baseline_rec) / NULLIF(baseline_rec,0) * 100)::numeric, 1),
    count(*)::int
  FROM weather_daily w
  JOIN health_metrics h ON h.user_id = w.user_id AND h.metric_date = w.date + interval '1 day'
  WHERE w.user_id = p_user_id AND w.daylight_min < 600
    AND h.hrv_avg > 0
  HAVING count(*) >= 3;
END;
$$;

COMMENT ON FUNCTION compute_weather_correlations IS 'Per-feature weather → health-delta. Surfaces "low pressure → HRV ↓X%" patterns.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. RLS
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE weather_daily        ENABLE ROW LEVEL SECURITY;
ALTER TABLE pc_app_categories    ENABLE ROW LEVEL SECURITY;
ALTER TABLE pc_activity          ENABLE ROW LEVEL SECURITY;
ALTER TABLE pc_system_samples    ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "users own weather_daily" ON weather_daily FOR ALL TO authenticated
    USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "users own pc_app_categories" ON pc_app_categories FOR ALL TO authenticated
    USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "users own pc_activity" ON pc_activity FOR ALL TO authenticated
    USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "users own pc_system_samples" ON pc_system_samples FOR ALL TO authenticated
    USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
