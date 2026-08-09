-- Account 1011 (U.S. Bank 4335, the agency's operating "Expenses" account) held statement
-- balances for Dec 2025 - May 2026 but ZERO transaction rows before 2026-05-27. The earlier
-- parse stopped at the summary block on every one of these five statements.
--
-- Source PDFs, all already in the Drive library and read directly for this migration:
--   26-01  1CYJtwQ6HbLlcdcap4f3pj1bCYfq3pC8j   Dec 24 2025 - Jan 27 2026
--   26-02  1IHyHA4bjyU2EYjeKmlDcyCpsqHk1pynF   Jan 28 - Feb 25 2026
--   26-03  1M_bVvhKweOl_xUgy0jNgAgsBCX9OndNn   Feb 26 - Mar 24 2026
--   26-04  1-gUsMi79kKDUihcrm3ibQ8O04xKdEAZp   Mar 25 - Apr 23 2026
--   26-05  1GgXH3xfTi7o807bXBpyziP-ttWFXX-TY   Apr 24 - May 26 2026
--
-- EVERY statement was reconciled to the penny against its own printed deposit and withdrawal
-- totals before this was written:
--   26-01  deposits 45,347.22  withdrawals 21,408.76   begin 61,934.54  end  85,873.00
--   26-02  deposits 22,488.37  withdrawals 22,153.70   begin 85,873.00  end  86,207.67
--   26-03  deposits 102,114.94 withdrawals 27,729.21   begin 86,207.67  end 160,593.40
--   26-04  deposits 10,395.08  withdrawals 42,791.26   begin 160,593.40 end 128,197.22
--   26-05  deposits 34,209.02  withdrawals 31,250.98   begin 128,197.22 end 131,155.26
-- Each closing balance equals the next opening balance, and 26-05 ends 2026-05-26, one day
-- before the earliest existing row (2026-05-27) - so there is no overlap and no double count.
--
-- Conventions matched to the rows already on this account: withdrawals carry a negative
-- amount with transaction_type 'withdrawal', deposits positive with 'deposit', and
-- descriptions use the compact "Electronic Withdrawal To <payee> <suffix>" form.
--
-- Inserted as a single statement so the post-on-arrival trigger fires exactly once. The 2026
-- floor inside that trigger keeps the two December 2025 rows out of the ledger; they belong to
-- prior_year_pl's period and are stored here for statement completeness only.

INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type, source_document_id)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       'b2222222-2222-2222-2222-222222222222', '4dc792cf-c087-47f9-b9ea-cbf1c43421f6', 'bank',
       v.txn_date, v.descr, v.amt, v.ttype, v.doc_id
FROM (VALUES
  -- ===== 26-01 : Dec 24 2025 - Jan 27 2026 =====
  (DATE '2026-01-20','Internet Banking Transfer From Account 104787443977', 45186.97,'deposit','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2026-01-27','Interest Paid',                                          160.25,'deposit','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2025-12-29','Mobile Banking Transfer To Account 104787443977',      -7200.00,'withdrawal','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2025-12-31','Electronic Withdrawal To HEALTH CARE SERV OBPPAYMT',   -1100.03,'withdrawal','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2026-01-06','Electronic Withdrawal To Ameritas Life In XS01DD',        -29.36,'withdrawal','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2026-01-06','Electronic Withdrawal To Ameritas Life In XS01DD',       -118.05,'withdrawal','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2026-01-08','Electronic Withdrawal To AMEX EPAYMENT ACH PMT',       -4641.86,'withdrawal','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2026-01-15','Electronic Withdrawal To CHASE CREDIT CRD',            -2478.95,'withdrawal','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  (DATE '2026-01-26','Internet Banking Transfer To Account 104787443977',    -5840.51,'withdrawal','93090174-012c-4767-93f4-8f9ad5d99772'::uuid),
  -- ===== 26-02 : Jan 28 - Feb 25 2026 =====
  (DATE '2026-02-04','Internet Banking Transfer From Account 104787443977',   9948.58,'deposit','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-18','Internet Banking Transfer From Account 104787443977',  12354.90,'deposit','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-25','Interest Paid',                                          184.89,'deposit','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-01-30','Electronic Withdrawal To HEALTH CARE SERV OBPPAYMT',   -1100.03,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-02','Electronic Withdrawal To CLEAR CHANNEL',                -860.00,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-04','Electronic Withdrawal To Ameritas Life In XS01DD',        -30.12,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-04','Electronic Withdrawal To Ameritas Life In XS01DD',       -147.36,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-05','Electronic Withdrawal To AMEX EPAYMENT ACH PMT',       -4815.63,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-09','Internet Banking Transfer To Account 104787443977',    -7646.62,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-17','Electronic Withdrawal To CHASE CREDIT CRD',            -2499.48,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  (DATE '2026-02-23','Internet Banking Transfer To Account 104787443977',    -5054.46,'withdrawal','0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid),
  -- ===== 26-03 : Feb 26 - Mar 24 2026 =====
  (DATE '2026-03-02','Internet Banking Transfer From Account 104787443977',  12815.35,'deposit','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-19','Internet Banking Transfer From Account 104787443977',  89089.22,'deposit','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-24','Interest Paid',                                          210.37,'deposit','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-02-27','Electronic Withdrawal To HEALTH CARE SERV OBPPAYMT',   -1100.03,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-02','Electronic Withdrawal To CLEAR CHANNEL',                -860.00,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-04','Electronic Withdrawal To Ameritas Life In XS01DD',        -49.98,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-04','Electronic Withdrawal To Ameritas Life In XS01DD',       -209.30,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-05','Electronic Withdrawal To AMEX EPAYMENT ACH PMT',       -3626.92,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-09','Internet Banking Transfer To Account 104787443977',    -6315.09,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-16','Electronic Withdrawal To CHASE CREDIT CRD',            -2703.80,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  (DATE '2026-03-19','Internet Banking Transfer To Account 212004766755',   -12864.09,'withdrawal','3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid),
  -- ===== 26-04 : Mar 25 - Apr 23 2026 =====
  (DATE '2026-04-03','Internet Banking Transfer From Account 104787443977',   9982.67,'deposit','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-10','Zelle Instant PMT From PAUL DROUIN',                     100.00,'deposit','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-23','Interest Paid',                                          312.41,'deposit','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-03-30','Mobile Banking Transfer To Account 104787443977',      -6042.97,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-03-30','Transfer Wdwl (Branch) To 373106263511',              -15000.00,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-03-31','Electronic Withdrawal To HEALTH CARE SERV OBPPAYMT',   -1100.03,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-02','Electronic Withdrawal To CLEAR CHANNEL',                -860.00,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-03','Electronic Withdrawal To Ameritas Life In XS01DD',        -40.05,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-03','Electronic Withdrawal To Ameritas Life In XS01DD',       -178.33,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-06','Electronic Withdrawal To AMEX EPAYMENT ACH PMT',       -3401.56,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-08','Internet Banking Transfer To Account 104787443977',    -5000.00,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-13','Mobile Banking Transfer To Account 104787443977',      -7905.76,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-15','Internet Banking Transfer To Account 104797420353',      -100.00,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  (DATE '2026-04-16','Electronic Withdrawal To CHASE CREDIT CRD',            -3162.56,'withdrawal','f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid),
  -- ===== 26-05 : Apr 24 - May 26 2026 =====
  (DATE '2026-04-27','Internet Banking Transfer From Account 104787443977',   5799.83,'deposit','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-06','Internet Banking Transfer From Account 104787443977',  13721.61,'deposit','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-20','Internet Banking Transfer From Account 104787443977',  14361.00,'deposit','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-26','Interest Paid',                                          326.58,'deposit','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-04-30','Electronic Withdrawal To CLEAR CHANNEL',                -860.00,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-04-30','Electronic Withdrawal To HEALTH CARE SERV OBPPAYMT',   -1100.03,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-05','Electronic Withdrawal To Ameritas Life In XS01DD',        -40.05,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-05','Electronic Withdrawal To Ameritas Life In XS01DD',       -178.33,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-07','Electronic Withdrawal To AMEX EPAYMENT ACH PMT',       -6076.48,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-11','Mobile Banking Transfer To Account 104787443977',      -6144.75,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-13','Internet Banking Transfer To Account 104787443977',    -4000.00,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-14','Electronic Withdrawal To CHASE CREDIT CRD',            -4844.24,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid),
  (DATE '2026-05-26','Mobile Banking Transfer To Account 104787443977',      -8007.10,'withdrawal','f77aac16-1a17-4696-83df-d345d17ae498'::uuid)
) AS v(txn_date, descr, amt, ttype, doc_id);
