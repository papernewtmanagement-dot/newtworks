-- Migration: fix_licensing_reimbursement_account_code_6715
-- Previous migration (20260708044500_add_licensing_reimbursement...) tried account_code 6740,
-- which was already taken by SF Conference & Travel. INSERT no-oped and the view pointed at
-- the wrong account. This migration inserts 6715 Licensing Reimbursement (between 6710 renewals
-- and 6720 CE) and repoints the view to 6715.
-- Applied via Supabase MCP 2026-07-08.

INSERT INTO public.chart_of_accounts (
  agency_id, account_code, account_name, account_type, account_subtype,
  parent_account_id, is_active, is_system, chart_namespace, business_entity_id
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  '6715',
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
WHERE a.account_code = '6715'
  AND a.chart_namespace = 'bcc_sf'
  AND DATE_TRUNC('year', COALESCE(je.entry_date, jl.created_at)) = DATE_TRUNC('year', CURRENT_DATE)
GROUP BY jl.agency_id, a.account_code, a.account_name, DATE_TRUNC('year', COALESCE(je.entry_date, jl.created_at));

COMMENT ON VIEW public.v_growth_budget_licensing_ytd IS
'YTD new-hire licensing reimbursement spend, sourced from journal_lines against COA 6715 (bcc_sf namespace). Complements v_growth_budget_ytd (salary+burden ramp) - together they cover the full growth-budget outlay. Neither should touch team-bonus-pool math.';
