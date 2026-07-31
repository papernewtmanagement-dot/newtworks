-- Migration: papernewt_add_6110_employee_benefits
-- Applied: 2026-07-31 via Supabase MCP
--
-- Adds Employee Benefits (6110) row on PaperNewt LLC entity so Leslie's life stipend
-- can classify to an expense account on PN's books directly.
-- Companion to step2_purge_legacy_coa_rules_rebuild_numeric.

INSERT INTO public.chart_of_accounts (
  agency_id, business_entity_id, account_code, account_name,
  account_type, account_subtype, is_active, is_system
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'b1111111-1111-1111-1111-111111111111',
  '6110', 'Employee Benefits', 'expense', 'benefits', true, false
)
ON CONFLICT DO NOTHING;
