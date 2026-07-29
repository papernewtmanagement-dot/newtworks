-- Follow-up: COA-UNCL-PSS *Unclassified (agency expense suspense) still orphan.
-- Same pattern as COA-SUB-088 Reimbursements pending — park under 0001 ADMINISTRATION.
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-019'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code='COA-UNCL-PSS';
