-- Follow-up: 6710 License Renewal Fees was orphan (no parent_account_id) and
-- didn't cascade under 6700 like 6715 does. Direct-parent under 0003 TEAM to
-- match its family (6700 Education & Licensing, 6715 Licensing Reimbursement,
-- 6720 CE, 6730 Training, 6740 SF Conference, 6750 Books).
UPDATE public.chart_of_accounts
SET parent_account_id = (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-020'
)
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id='b2222222-2222-2222-2222-222222222222'
  AND account_code='6710';

