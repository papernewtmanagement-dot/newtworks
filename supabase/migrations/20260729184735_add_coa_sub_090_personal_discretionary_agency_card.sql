-- New leaf under 0006 PERSONAL for personal-flavored charges landing on agency
-- cards (Plarium gaming, etc). Peter can later re-route these to Personal entity
-- as part of Phase 7 source-aware routing sweep; interim agency-side leaf keeps
-- them classified below the parent bucket.
INSERT INTO public.chart_of_accounts (
  agency_id, business_entity_id, account_code, account_name,
  account_type, is_active, parent_account_id
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'b2222222-2222-2222-2222-222222222222',
  'COA-SUB-090',
  'Personal - Discretionary (agency card)',
  'expense',
  true,
  (SELECT id FROM public.chart_of_accounts
     WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
       AND business_entity_id='b2222222-2222-2222-2222-222222222222'
       AND account_code='COA-022')
WHERE NOT EXISTS (
  SELECT 1 FROM public.chart_of_accounts
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND business_entity_id='b2222222-2222-2222-2222-222222222222'
    AND account_code='COA-SUB-090'
);

