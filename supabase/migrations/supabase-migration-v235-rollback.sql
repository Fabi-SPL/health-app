-- v235 rollback - drops the desktop-bridge heartbeat column. The phone then reads it as missing and stays on the
-- manual cadence.

BEGIN;

ALTER TABLE public.vrc_settings DROP COLUMN IF EXISTS pc_live_until;

COMMIT;

NOTIFY pgrst, 'reload schema';
