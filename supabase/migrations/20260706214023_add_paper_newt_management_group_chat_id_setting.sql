-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-06 21:40:23 UTC (ledger name: add_paper_newt_management_group_chat_id_setting) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260706214023.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Idempotent INSERT (no unique constraint on setting_key; check first)
INSERT INTO settings (agency_id, setting_key, setting_value, setting_type, description, updated_by, created_at, updated_at)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'paper_newt_management_group_chat_id',
  '-5518666399',
  'text',
  'Telegram chat_id for the Paper Newt Management group. paper_newt_bot member. Use with paper_newt_send_message.',
  'claude',
  NOW(),
  NOW()
WHERE NOT EXISTS (
  SELECT 1 FROM settings 
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND setting_key = 'paper_newt_management_group_chat_id'
);
