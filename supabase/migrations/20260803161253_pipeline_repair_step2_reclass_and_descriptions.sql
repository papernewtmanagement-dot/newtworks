-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-03 16:12:53 UTC (ledger name: pipeline_repair_step2_reclass_and_descriptions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260803161253.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

BEGIN;

ALTER TABLE public.chart_of_accounts
  ADD COLUMN IF NOT EXISTS description TEXT;

UPDATE public.chart_of_accounts SET description =
  'Peter Story State Farm operating checking / savings at U.S. Bank, account ending 4335. Statement description shows "U.S. Bank Smartly Savings". Primary agency cash account.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '1011' AND business_entity_id = 'b2222222-2222-2222-2222-222222222222';

UPDATE public.chart_of_accounts SET description =
  'Peter Story State Farm owner draws. Cash withdrawals from the agency to the owner, including transfers to personal accounts and CD funding. Equity, not expense.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '3020' AND business_entity_id = 'b2222222-2222-2222-2222-222222222222';

UPDATE public.chart_of_accounts SET description =
  'Personal-side clearing account for internal transfers between the household''s own accounts (agency, PaperNewt, personal bank, CDs). Zero-sum equity mover, not income or expense.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '3090' AND business_entity_id = 'b3333333-3333-3333-3333-333333333333';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC services and instruction income. Includes Lightshine school teaching engagements, AI/Claude-related consulting services, and any other services or instruction income received under the PaperNewt entity.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '4310' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC office supplies and general office expense. Amazon/retail miscellany, small equipment, office consumables, non-facility office decor.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '6910' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC software, apps, and SaaS subscriptions. Google Workspace/Fi, Amazon Prime, streaming used for business, any recurring digital service.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '6310' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC vehicle expenses. Gas/oil/fuel/maintenance purchases.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '6810' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC meals and entertainment. Restaurant charges, business meals, client entertainment.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '6860' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC repairs, maintenance, and facilities services. Security systems, HVAC, cleaning, facility repairs.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '6240' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC utilities and building services. Includes ADT security monitoring.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '6280' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC contra-expense for credit card cash rewards, rebates, statement credits. Reduces expense on the P&L.'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '6945' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

UPDATE public.chart_of_accounts SET description =
  'PaperNewt LLC cost of goods sold — printed products for resale. Print vendor purchases (4OVER, ND4C Houston, etc.).'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = '5100' AND business_entity_id = 'b1111111-1111-1111-1111-111111111111';

-- Reclass the 22 AMEX charges from PN 3050 S-Corp Distributions to real expense accounts
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='6910' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND created_by='claude_bank_reparse' AND description ILIKE '%AMAZON%') AND debit > 0;

UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='6310' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND created_by='claude_bank_reparse' AND (description ILIKE '%GOOGLE%' OR description ILIKE '%Amazon Prime%')) AND debit > 0;

UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='6280' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description ILIKE '%ADT%') AND debit > 0;

UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='6810' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description ILIKE '%BIGS%') AND debit > 0;

UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='6910' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description ILIKE '%BRICKS AND MINIFIGS%') AND debit > 0;

UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='6945' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description ILIKE '%AMERICAN EXPRESS CASH REBATE%') AND credit > 0;

-- Zelle from Paul Drouin -> agency Owner Draws
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='3020' AND business_entity_id='b2222222-2222-2222-2222-222222222222')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description ILIKE '%PAUL DROUIN%') AND credit > 0;

-- 4OVER -> PN COGS
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='5100' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description ILIKE '%4OVER%') AND debit > 0;

-- $50k CD funding -> agency Owner Draws
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='3020' AND business_entity_id='b2222222-2222-2222-2222-222222222222')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description = 'Debit' AND entry_date = '2026-06-08') AND debit = 50000;

-- $8,750 to Personal 0353 -> agency Owner Draws
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='3020' AND business_entity_id='b2222222-2222-2222-2222-222222222222')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description = 'Account 104797420353') AND debit > 0;

-- 7x Account 104787443977 -> Personal 3090 Internal Transfers
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='3090' AND business_entity_id='b3333333-3333-3333-3333-333333333333')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description = 'Account 104787443977')
AND account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='0003' AND business_entity_id='b2222222-2222-2222-2222-222222222222');

-- Imaginary Farms $250 -> PaperNewt Lightshine
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='4310' AND business_entity_id='b1111111-1111-1111-1111-111111111111')
WHERE journal_entry_id IN (SELECT id FROM journal_entries WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND classification_status='pending_review' AND description ILIKE '%IMAGINARY FARMS%') AND credit > 0;

-- Bug fix: 2 Jun 8/10 transfers on 6940 -> Personal 3090
UPDATE public.journal_lines
SET account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='3090' AND business_entity_id='b3333333-3333-3333-3333-333333333333')
WHERE journal_entry_id IN (
  SELECT je.id FROM journal_entries je
  WHERE je.agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND je.description = 'Internet Banking Transfer To Account 104787443977'
    AND je.entry_date IN ('2026-06-08','2026-06-10')
    AND je.classification_status = 'classified'
)
AND account_id = (SELECT id FROM chart_of_accounts WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='6940' AND business_entity_id='b2222222-2222-2222-2222-222222222222');

-- Memos
UPDATE public.journal_entries SET memo = 'Birthday money $100 from Peter''s father, sent via Zelle. Landed in the agency''s savings account (4335) by mistake — intended for the personal account. Pass-through per open question 2026-07-27. Offset booked to Owner Draws; when the paired outbound entry is found or created, it debits 3020 to zero out.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%PAUL DROUIN%';

UPDATE public.journal_entries SET memo = 'US Bank branch withdrawal 2026-06-08 funding certificate of deposit ending 3511 ($50,000, matures 8/24). Treated on the agency side as an owner distribution to Personal per 2026-07-28 direction. Personal-side CD asset creation tracked in open task "CD Batch 3".'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description = 'Debit' AND entry_date = '2026-06-08';

UPDATE public.journal_entries SET memo = 'Transfer from the agency''s savings account (4335) to Personal checking ending 0353 on 2026-07-14. Treated as owner draw.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description = 'Account 104797420353';

UPDATE public.journal_entries SET memo = 'Cash movement between the agency''s savings account (4335) and PaperNewt''s Business Checking (ending 3977). Treated as personal internal transfer via Personal 3090, matching majority historical pattern for unlabeled 104787443977 transfers. Not a payroll settlement — those historically carried a manual "Gas, Oil, Lube" descriptor and routed to 2902.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description = 'Account 104787443977';

UPDATE public.journal_entries SET memo = 'Imaginary Farms LLC $250 inbound via Zelle for Claude-related services. Cash landed in the agency''s savings (4335) but income belongs to PaperNewt LLC. Booked cross-entity: agency cash debit, PaperNewt 4310 (Lightshine and services income) credit.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%IMAGINARY FARMS%';

UPDATE public.journal_entries SET memo = 'Amazon purchase billed to the AMEX Discretionary card (2141) on PaperNewt. Routed to Office Supplies & Expense (6910).'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND (description ILIKE 'AMAZON MARKETPLACE%' OR description ILIKE 'AMAZON.COM%');

UPDATE public.journal_entries SET memo = 'Amazon Prime subscription billed to the AMEX Discretionary card (2141) on PaperNewt. Routed to Software & SaaS (6310).'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%Amazon Prime%';

UPDATE public.journal_entries SET memo = 'Google service billed to the AMEX Discretionary card (2141) on PaperNewt. Routed to Software & SaaS (6310).'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%GOOGLE%';

UPDATE public.journal_entries SET memo = 'ADT security monitoring, monthly recurring. Billed to the AMEX Discretionary card (2141) on PaperNewt. Routed to Utilities & Building Services (6280).'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%ADT%';

UPDATE public.journal_entries SET memo = 'BIGS 205 fuel purchase (gas station, confirmed 2026-07-31). Billed to the AMEX Discretionary card (2141). Routed to Vehicle Expenses (6810) on PaperNewt.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%BIGS%';

UPDATE public.journal_entries SET memo = 'Bricks and Minifigs LEGO purchase for office decorations at PaperNewt (confirmed 2026-07-31). Billed to the AMEX Discretionary card (2141). Routed to Office Supplies & Expense (6910).'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%BRICKS AND MINIFIGS%';

UPDATE public.journal_entries SET memo = 'American Express Cash Rebate credit on the AMEX Discretionary card (2141). Routed to Credit Card Rewards & Rebates contra-expense (6945) on PaperNewt.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%AMERICAN EXPRESS CASH REBATE%';

UPDATE public.journal_entries SET memo = '4OVER International print vendor purchase billed to the Citi 1247 printing card on PaperNewt. Routed to Printed Products for Resale COGS (5100).'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review' AND description ILIKE '%4OVER%';

UPDATE public.journal_entries SET memo = 'Cash movement between the agency''s savings account (4335) and PaperNewt''s Business Checking (ending 3977). Originally misclassified to 6940 Bank Fees & Charges. Corrected 2026-07-31 to 3090 Internal Transfers on Personal, matching the pattern applied to the seven pending 104787443977 transfers.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND description = 'Internet Banking Transfer To Account 104787443977' AND entry_date IN ('2026-06-08','2026-06-10') AND classification_status = 'classified';

-- Flip status on the 34 pending_review rows to classified
UPDATE public.journal_entries
SET classification_status = 'classified', classified_at = NOW(), classified_by = 'claude_step2_recovery_2026_07_31'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND classification_status = 'pending_review';

COMMIT;
