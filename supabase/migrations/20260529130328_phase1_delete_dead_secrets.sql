-- Phase 1 of secret hardening: remove secrets that NO Edge Function and NO
-- SQL function reads. Audit (2026-05-29) confirmed:
--   supabase_service_role_key  -> all functions use Deno.env.get(), table copy unused
--   supabase_personal_access_token -> zero reads anywhere
-- Both also live in the Supabase dashboard, so this is non-destructive to recoverability.
DELETE FROM settings
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key IN ('supabase_service_role_key','supabase_personal_access_token');
