-- Backfill missing bank transactions for US Bank Personal Checking 0353
-- Statements: 26-01 (Dec 20/25 - Jan 23/26), 26-02, 26-03, 26-07 (Jun 23 - Jul 21/26)
-- 26-04, 26-05, 26-06 already posted by prior pf4_personal_backfill run
-- Pattern matches Alvi's convention: one JE per txn, 2 journal_lines (0353 asset + category)


-- US Bank Personal Checking 26-01.pdf — 2025-12-20 → 2026-01-23
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2025-12-26', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-06', 'PERSONAL BACKFILL: Electronic Deposit From FAMILY PROTCT SV | INV-PAYMTS1746000089', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 800.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8400' THEN 800.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8400');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-08', 'PERSONAL BACKFILL: Electronic Deposit From TMHP | HIPP 9742638001', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 402.28 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8300' THEN 402.28 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8300');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-09', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-16', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.38 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.38 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-16', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-23', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.38 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.38 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-23', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-06', 'PERSONAL BACKFILL: Electronic Withdrawal To SA WATER SYSTEM | 9700295000WEB DEBITS008562294600142', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 126.36 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 126.36 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-08', 'PERSONAL BACKFILL: Electronic Withdrawal To CITY PUBLIC SRV | 9746002071CPS WEBPMT003004922036', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 230.86 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 230.86 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-16', 'PERSONAL BACKFILL: Electronic Withdrawal To MORTGAGE SERV CT | 4222195996MTG PAYMT 8018167836', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9100' THEN 1347.20 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1347.20 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9100','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-21', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766755', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 1426.23 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1426.23 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-21', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766755', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 1606.56 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1606.56 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');

-- US Bank Personal Checking 26-02.pdf — 2026-01-24 → 2026-02-23
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-28', 'PERSONAL BACKFILL: Cash Rewards Redemption', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 213.74 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8300' THEN 213.74 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8300');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-30', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.38 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.38 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-06', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-06', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-09', 'PERSONAL BACKFILL: Electronic Deposit From FAMILY PROTCT SV | INV-PAYMTS1746000089', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 800.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8400' THEN 800.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8400');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-13', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-18', 'PERSONAL BACKFILL: Internet Banking Transfer From Account 212004766730', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1000.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 1000.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-9990');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-20', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.37 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.37 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-20', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-26', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766730', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 7798.24 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 7798.24 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-01-28', 'PERSONAL BACKFILL: Internet Banking Payment To Credit Card *************8847', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 536.50 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 536.50 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-04', 'PERSONAL BACKFILL: Electronic Withdrawal To SA WATER SYSTEM | 9700295000WEB DEBITS008617556200142', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 132.36 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 132.36 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-05', 'PERSONAL BACKFILL: Electronic Withdrawal To CITY PUBLIC SRV | 9746002071CPS WEBPMT003004922036', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 271.11 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 271.11 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-09', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766730', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 3803.29 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 3803.29 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-18', 'PERSONAL BACKFILL: Electronic Withdrawal To MORTGAGE SERV CT | 4222195996MTG PAYMT 8018167836', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9100' THEN 1347.20 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1347.20 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9100','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-23', 'PERSONAL BACKFILL: Electronic Withdrawal To CAPITAL ONE | 9279744391ONLINE | PMTCA0DC8E208169EF', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 2696.77 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2696.77 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');

-- US Bank Personal Checking 26-03.pdf — 2026-02-24 → 2026-03-20
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-27', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-05', 'PERSONAL BACKFILL: Electronic Deposit From FAMILY PROTCT SV | INV-PAYMTS1746000089', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 800.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8400' THEN 800.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8400');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-06', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-06', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-13', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | IYTW 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.38 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.38 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-18', 'PERSONAL BACKFILL: Internet Banking Transfer From Account 212004766730', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1000.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 1000.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-9990');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-20', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | PAYROLL 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-20', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-02-25', 'PERSONAL BACKFILL: Internet Banking Payment To Credit Card *************8847', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 536.48 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 536.48 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-04', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766755', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 1300.20 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1300.20 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-05', 'PERSONAL BACKFILL: Electronic Withdrawal To SA WATER SYSTEM | 9700295000WEB DEBITS008674146900142', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 120.50 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 120.50 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-05', 'PERSONAL BACKFILL: Electronic Withdrawal To CITY PUBLIC SRV | 9746002071CPS WEBPMT003004922036', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 267.94 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 267.94 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-09', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766730', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 2989.95 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2989.95 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-18', 'PERSONAL BACKFILL: Electronic Withdrawal To MORTGAGE SERV CT | 4222195996MTG PAYMT 8018167836', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9100' THEN 1347.20 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1347.20 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9100','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-03-20', 'PERSONAL BACKFILL: Electronic Withdrawal To CAPITAL ONE | 9279744391ONLINE PMTCA0758CB0F7C670', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 2488.99 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2488.99 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');

-- US Bank Personal Checking 26-07.pdf — 2026-06-23 → 2026-07-21
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-06-26', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | PAYROLL 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.37 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.37 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-06-26', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-03', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | PAYROLL 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-07', 'PERSONAL BACKFILL: Electronic Deposit From FAMILY PROTCT SV | INV-PAYMTS1746000089', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 800.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8400' THEN 800.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8400');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-10', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | PAYROLL 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.39 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.39 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-10', 'PERSONAL BACKFILL: Electronic Deposit From GLOELE LLC | PAYROLL 4260302465', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2308.75 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8120' THEN 2308.75 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8120');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-14', 'PERSONAL BACKFILL: Internet Banking Transfer From Account 212003144335', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 8750.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 8750.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-9990');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-17', 'PERSONAL BACKFILL: Electronic Deposit From PAPERNEWT LLC | PAYROLL 1364350777', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 710.38 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-8110' THEN 710.38 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-0353','COA-PERSONAL-8110');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-06-29', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766730', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 3164.61 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 3164.61 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-01', 'PERSONAL BACKFILL: Internet Banking Payment To Credit Card *************8847', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 984.41 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 984.41 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-02', 'PERSONAL BACKFILL: Electronic Withdrawal To INDIAN SPRINGS R | 4270465600INDIAN SPRST-J7N9Z3E4F6E6', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9999' THEN 331.88 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 331.88 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9999','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-07', 'PERSONAL BACKFILL: Electronic Withdrawal To SA WATER SYSTEM | 9700295000PURCHASE 008911719200142', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 133.57 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 133.57 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-09', 'PERSONAL BACKFILL: Electronic Withdrawal To CITY PUBLIC SRV | 9746002071CPS WEBPMT003004922036', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9110' THEN 382.94 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 382.94 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9110','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-15', 'PERSONAL BACKFILL: Internet Banking Transfer To Account 212004766730', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9990' THEN 2696.73 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 2696.73 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9990','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-15', 'PERSONAL BACKFILL: Electronic Withdrawal To FID BKG SVC LLC | 1035141383MONEYLINE 243605784 4VTY4', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9610' THEN 8750.00 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 8750.00 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9610','COA-PERSONAL-0353');
WITH je AS (
  INSERT INTO public.journal_entries (agency_id, business_entity_id, entry_date, description, source)
  VALUES ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', '2026-07-20', 'PERSONAL BACKFILL: Electronic Withdrawal To MORTGAGE SERV CT | 4222195996MTG PAYMT 8018167836', 'chat_backfill_0353_20260727')
  RETURNING id
)
INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, business_entity_id)
SELECT je.id, '126794dd-25ff-47d2-a436-724499733365', coa.id,
       CASE WHEN coa.account_code='COA-PERSONAL-9100' THEN 1347.20 ELSE 0 END,
       CASE WHEN coa.account_code='COA-PERSONAL-0353' THEN 1347.20 ELSE 0 END,
       'b3333333-3333-3333-3333-333333333333'
FROM je, public.chart_of_accounts coa
WHERE coa.account_code IN ('COA-PERSONAL-9100','COA-PERSONAL-0353');

