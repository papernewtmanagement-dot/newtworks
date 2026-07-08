-- Extend weekly_cpr_team_detail with marketing bonus tracking cols
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS marketing_pool_points_ytd    NUMERIC,
  ADD COLUMN IF NOT EXISTS marketing_pool_share_pct     NUMERIC,
  ADD COLUMN IF NOT EXISTS marketing_pool_earned_ytd    NUMERIC,
  ADD COLUMN IF NOT EXISTS marketing_pool_earned_weekly NUMERIC,
  ADD COLUMN IF NOT EXISTS marketing_pool_diag          JSONB;

COMMENT ON COLUMN public.weekly_cpr_team_detail.marketing_pool_points_ytd IS 'YTD marketing points for this member';
COMMENT ON COLUMN public.weekly_cpr_team_detail.marketing_pool_share_pct  IS 'Share of total agency marketing points YTD (%)';
COMMENT ON COLUMN public.weekly_cpr_team_detail.marketing_pool_earned_ytd IS 'YTD share of marketing bonus pool (on-time)';
COMMENT ON COLUMN public.weekly_cpr_team_detail.marketing_pool_earned_weekly IS 'This-week delta: earned_ytd this week minus earned_ytd last week';
COMMENT ON COLUMN public.weekly_cpr_team_detail.marketing_pool_diag IS 'JSONB snapshot of envelope, spend, pool_ytd at this week end';
