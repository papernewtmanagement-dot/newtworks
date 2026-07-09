-- Pass 3 checkin copy tightening + eGain call log recipe composio_connection fix.
-- Applied via Supabase apply_migration on 2026-07-09; DB is source of truth.
--
-- Changes:
--   render_team_status_block: drop "Total:" line (redundant with WtW numerator);
--                             replace "  —  N to clear" with " 🔻N"
--   render_daily_calls_block: drop "Team:" summary line
--   team_health_checkin_compile: when goal is mathematically unreachable
--                                (hits + (6 - dow) < target), replace
--                                goal-implying hints with pure encouragement;
--                                restrict "one more workout" to Fri only.
--
-- Data fix (one-time UPDATE, not schema):
--   automation_recipes SET composio_connection='gmail' WHERE recipe_name='Call Log Parser (eGain daily intake)'.
--   The recipe had null composio_connection; runner rejected every cron fire.
--   Jul 7 data made it in via an earlier successful run; Jul 8+9 blocked.

SELECT 'See DB for canonical bodies; snapshot via schema_snapshots regeneration.' AS note;
