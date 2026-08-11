-- Kids Profit Disc (1072), Dec 24 2025 - Jan 27 2026 statement, 0 transactions on file.
-- Source: "US Bank KidsProfitDisc 26-01.pdf". All 14 printed lines inserted verbatim.
-- Deposits sum 30,977.36 + Withdrawals sum -29,194.63 = net +1,782.73, matching
-- opening 6,658.59 -> closing 8,441.32 exactly. Pre-verified zero.
INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type, source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       a.business_entity_id, a.id, 'bank', v.txn_date, v.descr, v.amt, v.ttype,
       'c17d9c4d-74db-43ff-9084-c5bc0f27dd9a'::uuid, 'Grunt packet rev4 — 0-txn month, full insert from source PDF'
FROM public.accounts a,
     (VALUES
       (DATE '2025-12-26','Electronic Deposit From PETER J STORY REF=253570120531570N00 7WQP 1364350779',288.46,'deposit'),
       (DATE '2025-12-26','Electronic Deposit From PETER J STORY REF=253570120531580N00 7WQP 1364350779',288.46,'deposit'),
       (DATE '2025-12-26','Electronic Deposit From PETER J STORY REF=253570120531590N00 7WQP 1364350779',288.46,'deposit'),
       (DATE '2025-12-26','Electronic Deposit From PETER J STORY REF=253570120531600N00 7WQP 1364350779',625.00,'deposit'),
       (DATE '2025-12-31','Electronic Deposit From PETER J STORY REF=253630275953010N00 7WQP 1364350779',110.00,'deposit'),
       (DATE '2025-12-31','Electronic Deposit From PETER J STORY REF=253630275953020N00 7WQP 1364350779',110.00,'deposit'),
       (DATE '2025-12-31','Electronic Deposit From PETER J STORY REF=253630275953030N00 7WQP 1364350779',110.00,'deposit'),
       (DATE '2026-01-07','Mobile Banking Transfer From Account 167502572545',21340.00,'deposit'),
       (DATE '2026-01-26','Internet Banking Transfer From Account 104797420353',7798.24,'deposit'),
       (DATE '2026-01-27','Interest Paid 2700103005',18.74,'deposit'),
       (DATE '2026-01-08','Electronic Withdrawal To AMEX EPAYMENT REF=260080078257420N00SD ACH PMT 0005000099',-21340.00,'withdrawal'),
       (DATE '2026-01-13','Internet Banking Transfer To Account 212004766755',-570.93,'withdrawal'),
       (DATE '2026-01-13','Internet Banking Transfer To Account 212004766755',-2283.70,'withdrawal'),
       (DATE '2026-01-21','Internet Banking Transfer To Account 212004766755',-5000.00,'withdrawal')
     ) AS v(txn_date, descr, amt, ttype)
WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND a.account_number_last4='6730';
