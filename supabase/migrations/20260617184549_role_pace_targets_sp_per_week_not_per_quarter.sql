-- Per Peter (2026-06-17): the 1000 / 500 sales-points figures are weekly rates,
-- not quarterly totals. Renaming the column to reflect the source-of-truth
-- semantic. Quarter totals derive as week_target × elapsed_weeks.

ALTER TABLE public.role_pace_targets
  RENAME COLUMN sales_points_per_quarter_target TO sales_points_per_week_target;

COMMENT ON COLUMN public.role_pace_targets.sales_points_per_week_target IS
  'Weekly sales-points rate per teammate at this (role_category, role_level). Cumulative quarterly target = this × elapsed weeks in quarter. Linear pace by construction.';

COMMENT ON COLUMN public.role_pace_targets.quotes_per_week_target IS
  'Weekly quotes target per teammate at this (role_category, role_level). Resets each week.';

-- Verify values are still correct (no rewrite needed — same numbers, different label)
UPDATE public.role_pace_targets
SET notes = CASE
  WHEN role_category='Sales' AND role_level='Account Manager'
    THEN 'AM Sales — 15 quotes/week + 1000 SP/week (cumulative 13,000 SP by quarter end)'
  WHEN role_category='Retention' AND role_level='Account Manager'
    THEN 'AM Retention — 8 quotes/week + 500 SP/week (cumulative 6,500 SP by quarter end). No current team member at this level.'
  ELSE notes
END,
updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
