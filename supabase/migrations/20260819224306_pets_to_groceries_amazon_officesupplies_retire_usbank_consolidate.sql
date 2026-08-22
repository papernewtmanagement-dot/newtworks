-- Peter directive 2026-08-19, three parts.

-- ============================================================
-- 1. PET SPENDING -> Groceries (9200). No new category.
-- ============================================================
-- Pet buys made at H-E-B / Costco / Sam's / Sprouts already land in Groceries
-- because those rules match the whole basket. Only Amazon pet items were
-- orphaned, so routing them to Groceries makes the picture consistent instead
-- of splitting pet spend across two homes.
INSERT INTO amazon_item_category_rules
  (agency_id, entity_name, target_business_entity_id, keyword_pattern,
   category_label, gl_account_code, priority, is_active, notes)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Personal',
  'b3333333-3333-3333-3333-333333333333',
  '\mdog\M|\mpuppy\M|\mcat litter\M|\mkitten\M|\mreptile\M|\mterrarium\M|\maquarium\M|\mgecko\M|\mbearded dragon\M|\mmealworm|\mcricket keeper\M|\mpet\s+(food|treat|bed|crate|carrier|toy)|\mleash\M|\mchew toy\M|\mflea\s+(and\s+tick|treatment)',
  'Personal - Pets',
  '9200',
  50,
  true,
  'Peter 2026-08-19: no new Pets category wanted. Pet spend folded into Groceries, matching where grocery-store pet buys already land. Deliberately narrow keywords: "cat" alone is excluded because it matches catalog/category/cable etc.'
);

-- ============================================================
-- 2. Retire the old Amazon -> Office Supplies rule on the AMEX.
-- ============================================================
-- Peter's test: kill it if it is a catch-all, keep it if it is a real targeted
-- rule. Its pattern is ^amazon(\s+marketplace|\.com|\s+mktpl) scoped to the
-- AMEX Discretionary card (2141) -- that covers essentially every Amazon
-- description on that card, so it is a catch-all wearing three variants, not a
-- targeted exception. It sits at priority 6 and therefore beat the newer
-- giveaways catch-all (priority 60) that Peter added later for the same card.
-- Newer instruction wins.
UPDATE gl_classification_rules
SET is_active = false,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_name = 'AMEX Discretionary — Amazon (Marketplace / .com) → 6910 Office Supplies'
  AND is_active;

-- NOT touched, on purpose: "AMEX Discretionary — Amazon Prime → 6310 Software"
-- is a genuinely specific rule (a named subscription, not all Amazon), and the
-- broader Retail -> Office Supplies rule covers other merchants entirely.

-- ============================================================
-- 3. Kill "US Bank (originations)" (4200) in favour of plain "US Bank" (4018).
-- ============================================================
-- 4200 was the account actually wired up, which is why it holds 7 rows /
-- $390.00 while 4018 sat empty at zero. Move the money and the wiring, then
-- retire 4200.

-- 3a. Move the existing postings.
UPDATE ledger
SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code = '4018'),
    memo = COALESCE(memo || ' | ', '')
           || 'Moved from 4200 US Bank (originations) to 4018 US Bank, Peter 2026-08-19'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_id = (SELECT id FROM chart_of_accounts WHERE account_code = '4200');

-- 3b. Repoint the compensation-statement wiring so future US Bank alliance
--     income lands on 4018.
UPDATE comp_category_map
SET source_account_code = '4018',
    source_account_name = 'US Bank',
    notes = COALESCE(notes || ' ', '')
            || 'Repointed 4200 -> 4018 (Peter 2026-08-19: retired the "originations" account).',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND source_account_code = '4200';

-- 3c. Retire 4200. The chart is locked by a trigger by design; drop, change,
--     recreate -- exactly the procedure the lock's own error message states.
DROP TRIGGER lock_chart_of_accounts ON public.chart_of_accounts;

UPDATE chart_of_accounts
SET is_active = false,
    account_name = 'US Bank (originations) — RETIRED, use 4018 US Bank'
WHERE account_code = '4200';

-- Carry 4018 forward with the subtype 4200 had, so it behaves the same way in
-- the profit-and-loss section logic.
UPDATE chart_of_accounts
SET account_subtype = 'sales'
WHERE account_code = '4018' AND account_subtype IS NULL;

CREATE TRIGGER lock_chart_of_accounts
  BEFORE INSERT OR UPDATE OR DELETE ON public.chart_of_accounts
  FOR EACH ROW EXECUTE FUNCTION public.block_chart_of_accounts_writes();
