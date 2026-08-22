-- 1) Chart of Accounts: 6740 Licensing Reimbursement (sub of 6700 Education & Licensing)
INSERT INTO public.chart_of_accounts (
  agency_id, account_code, account_name, account_type, account_subtype,
  parent_account_id, is_active, is_system, chart_namespace, business_entity_id
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  '6740',
  'Licensing Reimbursement',
  'expense',
  'licensing',
  parent.id,
  true,
  false,
  parent.chart_namespace,
  parent.business_entity_id
FROM public.chart_of_accounts parent
WHERE parent.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND parent.account_code = '6700'
  AND parent.chart_namespace = 'bcc_sf'
ON CONFLICT DO NOTHING;

-- 2) v_growth_budget_licensing_ytd — sums journal_lines against 6740 YTD.
-- Note: journal_lines has no team_member_id column. Description text may tag a name;
-- we surface the raw description alongside the amount so per-person attribution
-- can be added later via description parsing or a future team_member_id column.
CREATE OR REPLACE VIEW public.v_growth_budget_licensing_ytd AS
SELECT
  jl.agency_id,
  a.account_code,
  a.account_name,
  DATE_TRUNC('year', COALESCE(je.entry_date, jl.created_at))::date AS year_start,
  ROUND(SUM(COALESCE(jl.debit, 0) - COALESCE(jl.credit, 0)), 2) AS licensing_ytd_dollars,
  COUNT(*) AS entry_count,
  jsonb_agg(jsonb_build_object(
    'journal_entry_id', jl.journal_entry_id,
    'entry_date',       je.entry_date,
    'debit',            jl.debit,
    'credit',           jl.credit,
    'description',      jl.description
  ) ORDER BY je.entry_date DESC) AS entries
FROM public.journal_lines jl
JOIN public.chart_of_accounts a ON a.id = jl.account_id
LEFT JOIN public.journal_entries je ON je.id = jl.journal_entry_id
WHERE a.account_code = '6740'
  AND a.chart_namespace = 'bcc_sf'
  AND DATE_TRUNC('year', COALESCE(je.entry_date, jl.created_at)) = DATE_TRUNC('year', CURRENT_DATE)
GROUP BY jl.agency_id, a.account_code, a.account_name, DATE_TRUNC('year', COALESCE(je.entry_date, jl.created_at));

COMMENT ON VIEW public.v_growth_budget_licensing_ytd IS
'YTD new-hire licensing reimbursement spend, sourced from journal_lines against COA 6740 (bcc_sf namespace). Complements v_growth_budget_ytd (salary+burden ramp) — together they cover the full growth-budget outlay. Neither should touch team-bonus-pool math.';

-- 3) v_growth_budget_full_ytd — combined view: salary ramp + licensing YTD, reported against ceiling
CREATE OR REPLACE VIEW public.v_growth_budget_full_ytd AS
WITH salary_totals AS (
  SELECT
    agency_id,
    ROUND(SUM(growth_budget_ytd), 2) AS salary_ramp_ytd_dollars,
    SUM(weeks_ramping_ytd)           AS total_weeks_ramping_ytd,
    COUNT(*)                         AS active_new_hires_ramping
  FROM public.v_growth_budget_ytd
  GROUP BY agency_id
),
licensing_totals AS (
  SELECT agency_id, licensing_ytd_dollars, entry_count AS licensing_entries_ytd
  FROM public.v_growth_budget_licensing_ytd
)
SELECT
  COALESCE(s.agency_id, l.agency_id) AS agency_id,
  COALESCE(s.salary_ramp_ytd_dollars, 0)   AS salary_ramp_ytd_dollars,
  COALESCE(l.licensing_ytd_dollars, 0)     AS licensing_ytd_dollars,
  COALESCE(s.salary_ramp_ytd_dollars, 0) + COALESCE(l.licensing_ytd_dollars, 0) AS total_growth_budget_ytd_dollars,
  COALESCE(s.active_new_hires_ramping, 0)  AS active_new_hires_ramping,
  COALESCE(s.total_weeks_ramping_ytd, 0)   AS total_weeks_ramping_ytd,
  COALESCE(l.licensing_entries_ytd, 0)     AS licensing_entries_ytd
FROM salary_totals s
FULL OUTER JOIN licensing_totals l ON l.agency_id = s.agency_id;

COMMENT ON VIEW public.v_growth_budget_full_ytd IS
'Combined growth-budget YTD spend: salary+burden ramp (v_growth_budget_ytd) + new-hire licensing (v_growth_budget_licensing_ytd). Compare total_growth_budget_ytd_dollars against get_growth_budget_ceiling().ceiling_annual for utilization tracking.';
