-- 2026-07-11 seed_leaderboards_and_prize_cart_carryover
-- Seed floor config (100/50/5 round steps), Q1-Q4 2024-2026 quarter SP leaderboards,
-- best-week SP records (computed as QTD/13), Peter-provided quote records for Tommy,
-- and initial all-star counts. Carry unwon Q2 prizes to Q3, add 2 new prizes,
-- create Q3 budget row ($124.47 = 1% × on-time Scorecard).
-- Applied to production via Supabase MCP; see production for actual data rows.

INSERT INTO public.leaderboard_floor_config (category, round_step, round_direction, description) VALUES
  ('quarter_sp',  100, 'down', 'Quarter SP all-star floor: bronze rounded down to nearest $100'),
  ('week_sp',      50, 'down', 'Best Week SP all-star floor: bronze rounded down to nearest $50'),
  ('week_quotes',   5, 'down', 'Best Week Quotes all-star floor: bronze rounded down to nearest 5 quotes')
ON CONFLICT (category) DO NOTHING;
-- (Actual row inserts elided from repo mirror; live in production tables.)
