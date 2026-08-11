INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type,
   source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       a.business_entity_id, a.id, 'credit', '2026-01-07',
       'PETER J STORY ONLINE PAYMENT - THANK YOU', -4641.86, 'payment',
       'c17d9c4d-74db-43ff-9084-c5bc0f27dd9a',
       'Grunt packet rev4, AMEX Discretionary smoke test — monthly card payment skipped at parse, PAYMENT TEST match on printed THANK YOU line'
FROM public.accounts a
WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND a.account_number_last4='1003';
