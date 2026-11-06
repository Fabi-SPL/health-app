-- v235 - The 1s cadence turns itself on while the desktop bridge is live.
--
-- The desktop bridge stamps pc_live_until (now + a short TTL) on a heartbeat while it is running; the phone polls it
-- every 30s and pushes at 1s while it lies in the future, 10s otherwise. `enabled` stays only the bridge's remote
-- kill-switch; the phone's 1s/10s buttons are a local setting since v235. NULL or a past time = not live.
-- The existing owner policy ("users own vrc_settings", FOR ALL TO authenticated, uid() = user_id) and the
-- table-level UPDATE grant to authenticated already cover the new column; nothing to grant.
-- Rollback: supabase-migration-v235-rollback.sql

BEGIN;

ALTER TABLE public.vrc_settings ADD COLUMN IF NOT EXISTS pc_live_until timestamptz;

COMMENT ON COLUMN public.vrc_settings.pc_live_until IS
  'Desktop bridge heartbeat: live while this is in the future. The phone pushes at 1s while live, 10s otherwise.';

COMMIT;

NOTIFY pgrst, 'reload schema';
