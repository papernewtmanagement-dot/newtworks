-- Drop vestigial table. Zero rows ever, zero writers across DB + frontend
-- (verified 2026-07-13 via pg_get_functiondef sweep + full 67-file repo grep).
-- MVP prize wins are recorded in:
--   * mvp_history (identity + draw entitlement per week)
--   * prize_cart.winner_team_member_id + won_on (specific prize awarded)
DROP TABLE IF EXISTS public.mvp_prize_draws_log;
