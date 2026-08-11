INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type,
   source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       a.business_entity_id, a.id, 'credit', v.txn_date,
       'PETER J STORY ONLINE PAYMENT - THANK YOU', v.amt, 'payment',
       v.doc_id,
       'Grunt packet rev4, AMEX Discretionary — monthly card payment skipped at parse, PAYMENT TEST match on printed THANK YOU line; pre-verified exact-zero per THE ONE LAW'
FROM public.accounts a,
     (VALUES
       (DATE '2026-06-03', -3255.07, '0a328a31-4d4f-4faf-a279-6ce49ab67715'::uuid),
       (DATE '2026-07-01', -2964.26, '94f87593-bd30-47e8-9fb8-2e9f2eb48dde'::uuid)
     ) AS v(txn_date, amt, doc_id)
WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND a.account_number_last4='1003';
