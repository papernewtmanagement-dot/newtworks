-- Function-body rewrite for team_telegram_map → team migration
-- Applied 2026-07-16 to production via Supabase MCP
-- Retrieve exact body: SELECT unnest(statements) FROM supabase_migrations.schema_migrations WHERE version = '20260716182221';
-- Semantic summary: replaced JOIN public.team_telegram_map ttm ON ttm.team_id = t.id
--   with direct reads from public.team (telegram_user_id, is_excluded_pjsagencybot, is_excluded_paper_newt_bot).
-- This stub exists to keep repo migrations in sync with applied migration versions.
SELECT 1; -- no-op; actual DDL was CREATE OR REPLACE FUNCTION applied via MCP
