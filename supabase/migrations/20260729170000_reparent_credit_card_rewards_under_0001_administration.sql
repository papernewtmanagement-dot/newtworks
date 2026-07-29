-- Peter directive 2026-07-29: Credit Card Rewards & Rebates (COA 6945) currently
-- lives under the legacy "6900 General & Administrative" header. That header is
-- redundant with the "0001 ADMINISTRATION" parent (COA-019) in the seven-parent
-- taxonomy. Move 6945 directly under COA-019 so it renders inside the
-- Administration section on the agency P&L instead of surfacing a separate
-- "General & Administrative" section.
--
-- Scope: agency entity Peter Story State Farm (b2222222) only.
-- 6900 itself is left in place (is_active=true, no children after this move)
-- pending the broader legacy-header retirement decision.

UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'
    AND account_code = 'COA-019'
)
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'
  AND account_code = '6945';
