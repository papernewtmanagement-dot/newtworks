
-- Ingest all unprocessed US Bank Gmail alerts: May 29 – June 9, 2026
-- IDs already in register are excluded by the ON CONFLICT DO NOTHING

INSERT INTO bank_register_preliminary (
  agency_id, txn_date, account_type, account_last4, account_label,
  direction, amount, merchant,
  raw_subject, source_message_id, source_email_received_at,
  status, coding_status, coding_question,
  suggested_debit_account, suggested_credit_account, suggested_confidence,
  notes, created_at, updated_at
) VALUES

-- May 29: $25,614.19 DEPOSIT into 3977 — likely SF commission
('126794dd-25ff-47d2-a436-724499733365', '2026-05-29', 'checking', '3977', 'US Bank Business Checking ...3977',
 'credit', 25614.19, NULL,
 'Your transaction is complete.', '19e73b520f775f20', '2026-05-29 12:28:30+00',
 'unreconciled', 'needs_peter', 
 'A deposit of $25,614.19 hit your main checking account (3977) on May 29. Is this a State Farm commission deposit, a transfer from your other account, or something else?',
 NULL, NULL, 'low',
 'Unprocessed Gmail alert — ingested manually from backlog', now(), now()),

-- May 29: $1,100.03 OUT of 4335
('126794dd-25ff-47d2-a436-724499733365', '2026-05-29', 'checking', '4335', 'US Bank Business Checking ...4335',
 'debit', 1100.03, NULL,
 'Your transaction is complete.', '19e73c9d60896ea5', '2026-05-29 12:51:07+00',
 'unreconciled', 'needs_peter',
 'An outgoing transaction of $1,100.03 left your expense checking account (4335) on May 29. What is this for? (e.g. vendor payment, rent, insurance, other)',
 NULL, NULL, 'low',
 'Unprocessed Gmail alert — ingested manually from backlog', now(), now()),

-- May 30: $590.91 Amazon CC charge on 3439
('126794dd-25ff-47d2-a436-724499733365', '2026-05-30', 'credit_card', '3439', 'US Bank Business CC ...3439',
 'debit', 590.91, 'Amazon Mktpl*rl8zp9a33',
 'Your U.S. Bank business card has a new transaction.', '19e780c984a41cd9', '2026-05-30 08:42:30+00',
 'unreconciled', 'needs_peter',
 'Your business card (3439) was charged $590.91 at Amazon on May 30. What was this Amazon purchase for? (office supplies, equipment, marketing materials, other?)',
 NULL, NULL, 'low',
 'Unprocessed Gmail alert — ingested manually from backlog', now(), now()),

-- Jun 1: $19,355.29 OUT of 3977 — same amount/day as 4335 deposit = TRANSFER
('126794dd-25ff-47d2-a436-724499733365', '2026-06-01', 'checking', '3977', 'US Bank Business Checking ...3977',
 'debit', 19355.29, NULL,
 'Your transaction is complete.', '19e84cc253f3add0', '2026-06-01 20:07:11+00',
 'possible_transfer', 'needs_peter',
 '$19,355.29 left checking ...3977 AND the same amount showed up in checking ...4335 on the same day (June 1). This looks like a transfer between your two business checking accounts. Is that correct? If yes, no GL entry is needed — just a transfer.',
 NULL, NULL, 'medium',
 'Possible internal transfer — matches Jun 1 4335 deposit exactly', now(), now()),

-- Jun 1: $19,355.29 DEPOSIT into 4335 — matches 3977 debit = TRANSFER
('126794dd-25ff-47d2-a436-724499733365', '2026-06-01', 'checking', '4335', 'US Bank Business Checking ...4335',
 'credit', 19355.29, NULL,
 'Your transaction is complete.', '19e84ced1df4d181', '2026-06-01 20:10:06+00',
 'possible_transfer', 'needs_peter',
 'Deposit of $19,355.29 into checking ...4335 on June 1 — same amount left ...3977 the same day. Looks like an internal transfer. Confirm?',
 NULL, NULL, 'medium',
 'Possible internal transfer — matches Jun 1 3977 debit exactly', now(), now()),

-- Jun 3: $178.33 OUT of 4335
('126794dd-25ff-47d2-a436-724499733365', '2026-06-03', 'checking', '4335', 'US Bank Business Checking ...4335',
 'debit', 178.33, NULL,
 'Your transaction is complete.', '19e8d7c9bacafdbc', '2026-06-03 12:36:52+00',
 'unreconciled', 'needs_peter',
 'An outgoing payment of $178.33 left your expense checking account (4335) on June 3. What is this for?',
 NULL, NULL, 'low',
 'Unprocessed Gmail alert — ingested manually from backlog', now(), now()),

-- Jun 4: $7,742.45 OUT of 3977 — payroll cycle amount, Friday
('126794dd-25ff-47d2-a436-724499733365', '2026-06-04', 'checking', '3977', 'US Bank Business Checking ...3977',
 'debit', 7742.45, NULL,
 'Your transaction is complete.', '19e92943bdb56ed0', '2026-06-04 12:20:47+00',
 'unreconciled', 'needs_peter',
 'An outgoing transaction of $7,742.45 left your main checking account (3977) on June 4 (a Wednesday). This is similar in size to payroll runs we''ve seen before. Is this payroll, or something else like a vendor payment or draw?',
 NULL, NULL, 'medium',
 'Unprocessed Gmail alert — Jun 4, possible payroll', now(), now()),

-- Jun 4: $3,255.07 OUT of 4335
('126794dd-25ff-47d2-a436-724499733365', '2026-06-04', 'checking', '4335', 'US Bank Business Checking ...4335',
 'debit', 3255.07, NULL,
 'Your transaction is complete.', '19e929fe70015d15', '2026-06-04 12:33:33+00',
 'unreconciled', 'needs_peter',
 'An outgoing payment of $3,255.07 left your expense checking account (4335) on June 4. What is this payment for?',
 NULL, NULL, 'low',
 'Unprocessed Gmail alert — ingested manually from backlog', now(), now()),

-- Jun 5: $102.76 DEPOSIT into 3977 — small, likely interest or refund
('126794dd-25ff-47d2-a436-724499733365', '2026-06-05', 'checking', '3977', 'US Bank Business Checking ...3977',
 'credit', 102.76, NULL,
 'Your transaction is complete.', '19e97e0bd5c33c39', '2026-06-05 13:02:24+00',
 'unreconciled', 'needs_peter',
 'A small deposit of $102.76 came into checking ...3977 on June 5. This could be bank interest, a refund, or a small payment. Do you know what this is?',
 NULL, NULL, 'low',
 'Unprocessed Gmail alert — small deposit', now(), now()),

-- Jun 7: $50,000.00 OUT of 4335 — LARGE, needs immediate Peter answer
('126794dd-25ff-47d2-a436-724499733365', '2026-06-07', 'checking', '4335', 'US Bank Business Checking ...4335',
 'debit', 50000.00, NULL,
 'Your transaction is complete.', '19ea1fa3c8cd1d81', '2026-06-07 12:06:30+00',
 'unreconciled', 'needs_peter',
 '🚨 LARGE TRANSACTION: $50,000.00 left your expense checking account (4335) on June 7. This is the largest single transaction we have on record. What is this? (owner distribution/draw, tax payment, large vendor, investment, loan repayment, transfer to personal account?)',
 NULL, NULL, 'low',
 '⚠ HIGH PRIORITY — $50,000 debit from 4335, no merchant info. Needs Peter confirmation ASAP.', now(), now()),

-- Jun 8: $7,641.49 DEPOSIT into 3977 — same amount/day as 4335 transaction = TRANSFER
('126794dd-25ff-47d2-a436-724499733365', '2026-06-08', 'checking', '3977', 'US Bank Business Checking ...3977',
 'credit', 7641.49, NULL,
 'Your transaction is complete.', '19ea8d81ff804715', '2026-06-08 20:06:34+00',
 'possible_transfer', 'needs_peter',
 '$7,641.49 was deposited into checking ...3977 AND the same amount moved in checking ...4335 on June 8. Looks like another transfer between your two accounts. Confirm?',
 NULL, NULL, 'medium',
 'Possible internal transfer — matches Jun 8 4335 transaction amount', now(), now()),

-- Jun 8: $7,641.49 OUT of 4335 — matches 3977 deposit = TRANSFER
('126794dd-25ff-47d2-a436-724499733365', '2026-06-08', 'checking', '4335', 'US Bank Business Checking ...4335',
 'debit', 7641.49, NULL,
 'Your transaction is complete.', '19ea8da9466bd8a9', '2026-06-08 20:09:16+00',
 'possible_transfer', 'needs_peter',
 'Transaction of $7,641.49 from checking ...4335 on June 8 — same amount deposited to ...3977 same day. Internal transfer?',
 NULL, NULL, 'medium',
 'Possible internal transfer — matches Jun 8 3977 deposit amount', now(), now()),

-- Jun 8: $32.46 CREDIT on CC 3439 — could be a refund or cashback
('126794dd-25ff-47d2-a436-724499733365', '2026-06-08', 'credit_card', '3439', 'US Bank Business CC ...3439',
 'credit', 32.46, NULL,
 'U.S. Bank business credit card account - Credit posted', '19eac969bd2d5be1', '2026-06-09 13:33:30+00',
 'unreconciled', 'needs_peter',
 'A credit of $32.46 was posted to your business credit card (3439) on June 8. This means money came BACK onto the card. Is this a refund from a vendor, a cashback reward, or a billing correction?',
 NULL, NULL, 'low',
 'CC credit — could be refund, cashback, or correction', now(), now())

ON CONFLICT (source_message_id) DO NOTHING

