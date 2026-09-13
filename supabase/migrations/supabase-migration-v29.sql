-- Migration v29: Realtime health data from Whoop iOS BLE bridge
-- Stores live HR + RR + HRV readings streamed from the Bridge iOS app.
-- Auto-cleanup function: keep last 7 days to avoid unbounded growth.

-- ===== REALTIME HEALTH READINGS =====
CREATE TABLE IF NOT EXISTS realtime_health (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    heart_rate INTEGER,
    rr_intervals INTEGER[],
    hrv_rmssd NUMERIC,
    battery_pct NUMERIC,
    respiratory_rate NUMERIC,
    source TEXT DEFAULT 'whoop_ble',
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_realtime_health_user_time
    ON realtime_health (user_id, recorded_at DESC);

ALTER TABLE realtime_health ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own realtime health"
    ON realtime_health FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own realtime health"
    ON realtime_health FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Cleanup function: delete readings older than 7 days
CREATE OR REPLACE FUNCTION cleanup_old_realtime_health()
RETURNS void AS $$
BEGIN
    DELETE FROM realtime_health
    WHERE recorded_at < now() - INTERVAL '7 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ===== COGNITIVE READINESS LOG =====
CREATE TABLE IF NOT EXISTS cognitive_readiness_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    log_date DATE NOT NULL,
    morning_rmssd NUMERIC,
    morning_ln_rmssd NUMERIC,
    baseline_ln_rmssd NUMERIC,
    baseline_sd NUMERIC,
    readiness_level TEXT,
    sleep_hours NUMERIC,
    respiratory_rate_avg NUMERIC,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE (user_id, log_date)
);

ALTER TABLE cognitive_readiness_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own readiness log"
    ON cognitive_readiness_log FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own readiness log"
    ON cognitive_readiness_log FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own readiness log"
    ON cognitive_readiness_log FOR UPDATE
    USING (auth.uid() = user_id);
