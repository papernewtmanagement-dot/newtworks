-- Align trailblazer_crossings column names with all_star_crossings for consistency.
-- Both tables serve the same purpose (record a person crossing a numeric threshold for a
-- leaderboard category in a given week), but originally shipped with different column names.
-- Every caller had to remember which shape it was. Consolidated on the all_star shape
-- (value_at_crossing / floor_at_crossing).
--
-- Callers updated in-migration: audit_weekly_leaderboard_crossings (INSERT), compose_weekly_cpr_html
-- (SELECT). Frontend callers (CPRDetail.jsx .select() + LeaderboardsSection render) updated in
-- follow-up commit 443e6f87.

ALTER TABLE public.trailblazer_crossings
  RENAME COLUMN crossing_value TO value_at_crossing;

ALTER TABLE public.trailblazer_crossings
  RENAME COLUMN threshold_at_crossing TO floor_at_crossing;

-- audit_weekly_leaderboard_crossings + compose_weekly_cpr_html function bodies were also
-- updated in this migration. See DB reality (pg_proc) for canonical function source; the two
-- CREATE OR REPLACE bodies are omitted from this mirror file since they are long and their
-- only functional change was s/crossing_value/value_at_crossing/ and s/threshold_at_crossing/floor_at_crossing/
-- in the trailblazer INSERT/SELECT clauses. All other logic identical to their prior versions.
