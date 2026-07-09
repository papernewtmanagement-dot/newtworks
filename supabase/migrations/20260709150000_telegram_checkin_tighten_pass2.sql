-- Pass 2: apply Peter's follow-up compaction spec across all checkins.
-- See commit message for the full change list. This mirrors the migration that
-- was applied via Supabase MCP; source of truth remains the DB.

-- Full SQL body committed via Supabase apply_migration on 2026-07-09.
-- Snapshot lives in supabase/schema_snapshots/functions_YYYY-MM-DD.sql when regenerated.

-- Signatures changed:
--   render_team_status_block: added encouragement_text column to return record
-- Signatures unchanged (bodies updated):
--   team_checkin_send_reminder, team_checkin_compile_results,
--   render_daily_calls_block, team_health_checkin_prompt,
--   team_health_checkin_compile

SELECT 'See DB for canonical body. Regenerate schema_snapshots/functions_YYYY-MM-DD.sql to capture.' AS note;
