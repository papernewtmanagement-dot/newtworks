-- US Bank Other Income (1071), Dec 9 2025 - Jan 9 2026 statement, 0 transactions on file.
-- Source: "US Bank Other Income 26-01.pdf" (via Drive zip, extracted_text was empty).
-- Deposits 31,866.74 + Withdrawals -28,170.00 = net +3,696.74, matching opening 1,795.43
-- -> closing 5,492.17 exactly. Pre-verified zero.
-- NOTE: Jan 7 withdrawal to Account 212004766730 is the mirror side of the Kids Profit
-- Disc (1072) Jan 7 deposit already flagged unclassified this session.
INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type, source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       a.business_entity_id, a.id, 'bank', v.txn_date, v.descr, v.amt, v.ttype,
       '8f4f1d79-6d26-479c-9773-6494ba98c8f8'::uuid, 'Grunt packet rev4 — 0-txn month, full insert from source PDF (via Drive zip)'
FROM public.accounts a,
     (VALUES
       (DATE '2025-12-10','Internet Banking Transfer From Account 212004766755',4516.00,'deposit'),
       (DATE '2025-12-12','Electronic Deposit From SMVC TRUCKING & REF=253450139401570N00 6URW 1364350779',310.00,'deposit'),
       (DATE '2025-12-16','Internet Banking Transfer From Account 212004766730',500.00,'deposit'),
       (DATE '2025-12-19','Electronic Deposit From SMVC TRUCKING & REF=253520130597040N00 6URW 1364350779',310.00,'deposit'),
       (DATE '2025-12-26','Electronic Deposit From SMVC TRUCKING & REF=253580089258830N00 6URW 1364350779',465.00,'deposit'),
       (DATE '2026-01-02','Electronic Deposit From SMVC TRUCKING & REF=253650171431160N00 6URW 1364350779',310.00,'deposit'),
       (DATE '2026-01-07','Transfer Deposit From 373106526156',25455.74,'deposit'),
       (DATE '2025-12-12','Electronic Withdrawal To IRS REF=253460138562580N00SD USATAXPYMT3387702000',-4516.00,'withdrawal'),
       (DATE '2025-12-17','Electronic Withdrawal To SBA EIDL LOAN REF=253500160831620N00 7300000118PAYMENT 6RH1P0ACAD1',-2314.00,'withdrawal'),
       (DATE '2026-01-07','Mobile Banking Transfer To Account 212004766730',-21340.00,'withdrawal')
     ) AS v(txn_date, descr, amt, ttype)
WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND a.account_number_last4='2545';
