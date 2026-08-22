-- Ingest June 2026 statements for US Bank Income 3977 and Chase Ink CC (7762+7770)
-- Documents catalogued 2026-07-16; parsing was never run. Peter directive 2026-07-27.
-- bank_transactions.bank_account_id → chart_of_accounts.id (COA-007 for US Bank Income).
-- credit_transactions.credit_account_id → credit_accounts.id (7762 + 7770 rows).

-- =========================================================================
-- US Bank Silver Business Checking 3977 — Jun 1-30, 2026
-- 8 deposits ($54,058.13), 13 withdrawals ($53,378.59). Ending $30,034.83.
-- =========================================================================

INSERT INTO public.bank_transactions
  (agency_id, bank_account_id, business_entity_id, transaction_date, description, amount, transaction_type, source_document_id, posting_source, notes)
VALUES
-- Deposits
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-05', $$Electronic Deposit From Hagerty Drivers PAYMENTS 498740$$, 24.00, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261540072001970N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-05', $$Electronic Deposit From GAINSCO INS COMP COMM PMNT A79716$$, 102.76, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261550110891630N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-08', $$Internet Banking Transfer From Account 212003144335$$, 7641.49, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', NULL),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-10', $$Internet Banking Transfer From Account 212003144335$$, 5000.00, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', NULL),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-15', $$Electronic Deposit From STATE FARM 9778910709 AGENCYCOMP 531BDDSA9000000$$, 19220.32, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261620065183090N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-17', $$Mobile Check Deposit$$, 56.02, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 8652020506'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-29', $$Internet Banking Transfer From Account 212003144335$$, 1952.91, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', NULL),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-30', $$Electronic Deposit From STATE FARM 9778910709 AGENCYCOMP 531BDDSA9000000$$, 20060.63, 'deposit', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261770048440390N00'),
-- Withdrawals
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-01', $$Internet Banking Transfer To Account 212003144335$$, -19355.29, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', NULL),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-02', $$Electronic Withdrawal To MYCHILDSUPPORT WDACOJC5IJO8P1$$, -25.80, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261520177199270N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-04', $$Electronic Withdrawal To PAYROLL SERVICE 1364350777IYTW$$, -7742.45, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261540020675850N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-09', $$Electronic Withdrawal To MYCHILDSUPPORT WEKAUBKB1T2ZMF$$, -25.80, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261590129696940N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-10', $$Internet Banking Payment To Credit Card ending 3447$$, -4968.30, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', NULL),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-11', $$Electronic Withdrawal To PAYROLL SERVICE 1364350777IYTW$$, -6834.77, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261610025759470N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-16', $$Electronic Withdrawal To MYCHILDSUPPORT WFU92AMI2VHAT2$$, -25.80, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261660217235160N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-16', $$Electronic Withdrawal To VENMO 3264681992 PAYMENT 1051014949883$$, -1250.00, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261660217741280N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-18', $$Electronic Withdrawal To ONLINE PAYROLL 0000217279 PAYROLL 8617549$$, -21.30, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261690070673460N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-18', $$Electronic Withdrawal To PAYROLL SERVICE 1364350777IYTW$$, -7087.05, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261680089860350N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-23', $$Electronic Withdrawal To MYCHILDSUPPORT WH477MPJ0O0M0R$$, -25.80, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261730260915390N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-25', $$Electronic Withdrawal To PAYROLL SERVICE 1364350777IYTW$$, -5990.43, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261750080355820N00'),
('126794dd-25ff-47d2-a436-724499733365','6962a8d3-57b9-423f-be93-c4a14c49a4d5','b2222222-2222-2222-2222-222222222222','2026-06-30', $$Electronic Withdrawal To MYCHILDSUPPORT WIE5F28BWRMPM$$, -25.80, 'withdrawal', '96c13bcc-6fc3-4489-bec7-aa5a06c84272', 'statement_pdf', 'Ref 261800197948880N00');

-- =========================================================================
-- Chase Ink Business — cycle 05/23/26 - 06/22/26
-- Payment $4,986.04 on 7762 (Peter). Charges $3,923.55 all on 7770 (Marie).
-- Consolidated statement covers both cards per Alvi confirmation (see doc notes).
-- =========================================================================

INSERT INTO public.credit_transactions
  (agency_id, credit_account_id, business_entity_id, transaction_date, description, amount, transaction_type, source_document_id, notes)
VALUES
-- 7762 (Peter): the payment
('126794dd-25ff-47d2-a436-724499733365','37c0a92a-66b8-42d4-a602-cd36734f375f','b2222222-2222-2222-2222-222222222222','2026-06-15', $$Payment Thank You - Web (Peter J Story)$$, -4986.04, 'payment', 'f26f0020-7590-45c8-9469-029e889c95e7', 'Full cycle payment on card 7762'),
-- 7770 (Marie): all EverQuote / Butler-Till / Agent Tag marketing spend
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-05-24', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-05-25', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-05-31', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-01', $$AGENT TAG* AGENT TAGGE BUTLERTILL.CO NY$$, 309.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-01', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 600.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-10', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-11', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-15', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-17', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-17', $$BUTLER/TILL AGENTHOODPROG NY$$, 1014.55, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL),
('126794dd-25ff-47d2-a436-724499733365','4d1af9e2-dff4-4a48-aec5-5c13ed7a5205','b2222222-2222-2222-2222-222222222222','2026-06-18', $$EVERQUOTE, INC PRO.EVERQUOTE MA$$, 250.00, 'charge', 'f26f0020-7590-45c8-9469-029e889c95e7', NULL);

-- Update documents rows: mark processed + populate records_created
UPDATE public.documents
SET processing_status = 'processed',
    records_created = 21,
    tables_updated = ARRAY['bank_transactions'],
    processed_at = NOW(),
    notes = COALESCE(notes, '') || ' | Parsed 2026-07-27 by Claude session (21 rows: 8 deposits $54,058.13, 13 withdrawals $53,378.59; ending $30,034.83 matches statement).'
WHERE id = '96c13bcc-6fc3-4489-bec7-aa5a06c84272';

UPDATE public.documents
SET processing_status = 'processed',
    records_created = 12,
    tables_updated = ARRAY['credit_transactions'],
    processed_at = NOW(),
    notes = COALESCE(notes, '') || ' | Parsed 2026-07-27 by Claude session (12 rows: -$4,986.04 payment on 7762, +$3,923.55 charges on 7770; new balance $3,923.55 matches statement).'
WHERE id = 'f26f0020-7590-45c8-9469-029e889c95e7';
