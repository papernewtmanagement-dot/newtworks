-- Card 2113 (US Bank Business Cash Rewards 3447), period 2026-01-17 to 2026-02-17, reported a
-- -422.50 variance. Read from source (US Bank CC 26-02.pdf, Drive 1M94khAbNSVVmQFk-OJtpyPsxh6gKw2-c):
-- two STATE FARM INSURANCE charges of 189.85 and 232.65 on the Peter sub-account, which sum to
-- exactly 422.50. Both were absent; every other line in the period was present and correct.
--
-- ROOT CAUSE, and it is NOT what the 2026-08-08 handoff guessed. The handoff called this "a
-- transaction dated on the wrong side of a close". It is a TRANSACTION-DATE vs POSTING-DATE
-- straddle: both charges carry trans date 01/16 and post date 01/20. The statement's open date is
-- 01/17, so a parser filtering on trans date drops them - even though the bank counts them in this
-- period (Previous 1,459.35 - Payments 1,459.35 - Credits 248.64 + Purchases 2,372.18 = New
-- 2,123.54, and the 2,372.18 only reconciles WITH these two included).
--
-- DATE CHOICE, made deliberately and flagged rather than assumed: stored under the POSTING date
-- 01/20, not the trans date 01/16. v_statement_reconciliation groups by transaction_date between
-- the period bounds, so storing 01/16 would leave the period failing while the bank's own
-- arithmetic says it balances. The statement asserts these belong to this period; the stored date
-- follows that. This departs from the house habit of storing trans date, and applies ONLY to rows
-- whose trans date precedes the statement open date. If Peter prefers trans date preserved, the
-- reconciliation view needs to bound on posting date instead - that is a bigger change and was not
-- made unilaterally.

INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type, source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       a.business_entity_id, a.id, 'credit',
       v.txn_date, v.descr, v.amt, 'charge',
       (SELECT id FROM documents WHERE file_name='US Bank CC 26-02.pdf' LIMIT 1),
       'Posting date used; trans date on statement is 2026-01-16, before the 01/17 open date.'
FROM public.accounts a,
     (VALUES
       (DATE '2026-01-20','STATE FARM INSURANCE 800-956-6310 IL', 189.85),
       (DATE '2026-01-20','STATE FARM INSURANCE 800-956-6310 IL', 232.65)
     ) AS v(txn_date, descr, amt)
WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND a.account_number_last4='3447';
