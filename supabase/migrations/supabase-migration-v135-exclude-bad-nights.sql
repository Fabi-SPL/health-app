-- v135: mark unreliable days so they never pollute real scores/baselines/trends.
-- Trigger: nights where BLE flapped (code-6 timeouts) so hard that no continuous
-- realtime stream persisted AND history backfill recovered 0 records -> the day's
-- sleep/recovery/battery are garbage. Jun 13 2026 is the first (heavy drinking,
-- HR 100-140 awake all night, 34+ BLE disconnects, 6.7h hole 22:43->05:24).
--
-- Approach: a boolean flag + reason on health_metrics. Excluded rows keep their raw
-- timestamps for audit but their headline numbers are nulled so nothing fake renders,
-- and every baseline/trend reader must filter excluded=false.

ALTER TABLE public.health_metrics
  ADD COLUMN IF NOT EXISTS excluded boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS exclude_reason text;

-- mark Jun 13 2026 excluded + null the misleading headline scores
UPDATE public.health_metrics
SET excluded = true,
    exclude_reason = 'BLE code-6 timeout flapping all night (34+ disconnects) + history backfill returned 0 records -> 6.7h hole 22:43-05:24. Heavy drinking, HR 100-140 awake all night, no sleep window detected. Sleep/recovery/battery unreliable.',
    body_battery = NULL,
    body_battery_anchor = NULL,
    bb_effective = NULL,
    strain_score = NULL,
    recovery_score = NULL,
    readiness_score = NULL
WHERE user_id = '372210e5-1dda-41b3-b759-5ff72293b8ff'
  AND metric_date = '2026-06-13';
