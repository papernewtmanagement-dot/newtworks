-- Populate last4 on 3 personal bank accounts from statement headers (2026-07-21 batch)
UPDATE public.bank_accounts SET account_number_last4 = '0353', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b3333333-3333-3333-3333-333333333333'
  AND account_name = 'US Bank Personal Checking';

UPDATE public.bank_accounts SET account_number_last4 = '6730', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b3333333-3333-3333-3333-333333333333'
  AND account_name = 'US Bank Kids Profit Disc';

UPDATE public.bank_accounts SET account_number_last4 = '2545', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b3333333-3333-3333-3333-333333333333'
  AND account_name = 'US Bank Other Income';
