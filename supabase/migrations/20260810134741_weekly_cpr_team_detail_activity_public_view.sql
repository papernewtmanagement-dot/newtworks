-- Team Activity section on CPR page was only showing each non-admin viewer
-- their own row. Root cause: weekly_cpr_team_detail_admin_or_own_read (added
-- 20260805040457) is a row-level policy, so a select("*") from the base
-- table drops every OTHER teammate's row entirely for a non-admin viewer --
-- including harmless activity fields (quotes, sales points, checklist,
-- production counts) that were never meant to be comp-restricted. Comp
-- columns (pay, bonuses, pools, warning/coverage/profitability metrics,
-- residual_pool_diag) correctly stay admin-or-own -- that part was not a bug.
--
-- Same split already established for `team` -> `team_directory` (directory
-- columns team-wide, annual_benefits_value stays on the restricted table,
-- merged client-side). This view is the same pattern for
-- weekly_cpr_team_detail: activity/production/checklist columns only, no
-- dollar figures, no *_diag, no pay/bonus/pool/warning/coverage/
-- profitability/lapse/retention_quality columns.
--
-- View is owned by postgres (table owner, RLS-bypassing), so it reads every
-- row for the week regardless of the base table's admin-or-own policy.
-- Frontend merges: base-table fetch (admin-or-own, full comp fields) stays
-- primary; any team_member_id missing from that result (i.e. RLS dropped it
-- for a non-admin viewer) gets filled in from this view with comp fields
-- left null -- mirrors the existing annual_benefits_value merge pattern in
-- CPRDetail.jsx.

CREATE OR REPLACE VIEW public.weekly_cpr_team_detail_activity AS
SELECT
  id,
  agency_id,
  weekly_cpr_report_id,
  team_member_id,
  code_reds,
  code_yellows,
  wrapup_done,
  inbox_done,
  wrapup_text,
  quotes_discussed,
  quotes_modified,
  sales_points,
  sales_points_v01,
  scorecard_done,
  prod_total_count,
  prod_total_premium,
  prod_issued_count,
  prod_issued_premium,
  prod_auto,
  prod_fire,
  prod_life,
  prod_health,
  prod_bank,
  wtw_requirements_adjustment_quotes,
  role,
  role_level,
  role_category,
  category,
  first_name,
  last_name,
  nickname,
  is_active,
  archived_at,
  is_admin_backoffice,
  is_test_user,
  start_date,
  end_date,
  hire_date,
  work_location,
  license_pc,
  license_lh,
  license_ips,
  created_at,
  updated_at
FROM public.weekly_cpr_team_detail;

GRANT SELECT ON public.weekly_cpr_team_detail_activity TO authenticated;
