-- v137: make the BLE sync cursor DEVICE-AGNOSTIC so it can finally become the
-- authoritative gap source (kills the repeating silent-backfill-miss regression:
-- May 7, May 21, Jun 13).
--
-- Root cause found 2026-06-13: every realtime_health row has device_id = NULL
-- (the device_id/device_seq plumbing was never wired into the iOS inserts), but
-- the v104 view did `WHERE device_id IS NOT NULL GROUP BY device_id` -> it
-- returned ZERO rows for the user -> fetchSyncCursor always hit the "no rows =
-- first sync" branch -> the shadow logged server=backfill_first_sync forever and
-- could never overrule the clobbered UserDefaults timestamp.
--
-- The only ground truth the client cannot clobber is MAX(recorded_at) per user.
-- device_seq stays exposed as last_seq for forward-compat (still NULL today), but
-- the decision now rides on last_recorded_at / minutes_since_last.

CREATE OR REPLACE VIEW public.v_ble_sync_cursor AS
SELECT
  user_id,
  NULL::text                                                         AS device_id,
  max(device_seq)                                                    AS last_seq,
  max(recorded_at)                                                   AS last_recorded_at,
  EXTRACT(epoch FROM now() - max(recorded_at)) / 60::numeric         AS minutes_since_last
FROM public.realtime_health
WHERE heart_rate > 20            -- ignore junk / null-HR sentinel rows
GROUP BY user_id;
