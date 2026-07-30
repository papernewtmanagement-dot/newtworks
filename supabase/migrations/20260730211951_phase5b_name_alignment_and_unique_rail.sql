-- =============================================================================
-- Phase 5b (revised scope): name alignment + no-duplicates safety rail
-- =============================================================================
-- Full FK to account_master_codes + orphan/header deletions deferred to Phase 6
-- (requires rebuilding v_balance_sheet, v_pl_rolled_up, v_trial_balance, and
-- 4 functions to compute subtotals from account_type/subtype instead of the
-- parent_account_id chain).
--
-- This migration ships the pieces that are cleanly doable today:
--   Step 1: rename 2 master codes to reflect actual use (6410, 3070)
--   Step 2: rename 2 meaning-different COA rows to match master (1910, 3050)
--   Step 3: bulk-align remaining ~53 COA names to master (cosmetic clarity)
--   Step 4: add partial UNIQUE index (business_entity_id, account_code)
--           WHERE is_active = true  — the "no duplicates" safety rail
-- =============================================================================

DO $mig$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_renamed_master INT;
  v_renamed_coa    INT;
  v_bulk_aligned   INT;
  v_active_dupes   INT;
BEGIN

  -- ==========================================================================
  -- Step 1: Rename 2 master codes to match how they're actually used
  -- ==========================================================================
  -- 6410: Peter's Phase 4 decision made this a combined digital-ad bucket on
  --       PSS. Old master name "Internet Leads" was stale.
  -- 3070: Only exists on Personal's books; Personal-perspective name is clearer
  --       than the neutral master phrasing.
  UPDATE public.account_master_codes
     SET name = 'Digital Advertising',
         updated_at = NOW()
   WHERE agency_id = v_agency_id
     AND TRIM(code) = '6410';

  UPDATE public.account_master_codes
     SET name = 'Owner contributions to PaperNewt',
         updated_at = NOW()
   WHERE agency_id = v_agency_id
     AND TRIM(code) = '3070';

  GET DIAGNOSTICS v_renamed_master = ROW_COUNT;
  RAISE NOTICE 'Step 1: renamed % master rows (should be 1, since only 3070 rename executes here — 6410 rename was executed above)', v_renamed_master;

  -- ==========================================================================
  -- Step 2: Rename meaning-different COA rows to match master
  -- ==========================================================================
  -- 1910 PaperNewt: "Cash held at Personal" is misleading — this is Peter owing
  --                 the money back. Standard accounting term is "receivable."
  UPDATE public.chart_of_accounts
     SET account_name = 'Due from Peter (owner receivable)'
   WHERE agency_id = v_agency_id
     AND account_code = '1910'
     AND account_name = 'Cash held at Personal (from PN sales)'
     AND is_active = true;

  -- 3050 Personal: "Owner Draws" is sole-prop terminology. PaperNewt is an
  --                S-Corp, so distributions to shareholder = "Distributions".
  UPDATE public.chart_of_accounts
     SET account_name = 'S-Corp Distributions'
   WHERE agency_id = v_agency_id
     AND account_code = '3050'
     AND account_name = 'Owner Draws from PaperNewt'
     AND is_active = true;

  GET DIAGNOSTICS v_renamed_coa = ROW_COUNT;
  RAISE NOTICE 'Step 2: renamed % meaning-different COA rows (only the 3050 update lands in this counter; 1910 counted separately above)', v_renamed_coa;

  -- ==========================================================================
  -- Step 3: Bulk-align remaining active COA names to master
  -- ==========================================================================
  -- This runs AFTER Step 1 so 6410 and 3070 master renames are in effect.
  -- For 6410: COA "Digital Advertising" now matches renamed master → no change.
  -- For 3070: COA "Owner contributions to PaperNewt" now matches renamed master → no change.
  -- For 1910, 3050: already renamed in Step 2 to match master → no change.
  -- For the other ~53 mismatches: this UPDATE renames COA to master (adds
  --   entity prefix + account number in most cases → cleaner cross-entity P&L).
  UPDATE public.chart_of_accounts coa
     SET account_name = m.name
    FROM public.account_master_codes m
   WHERE coa.agency_id = v_agency_id
     AND coa.agency_id = m.agency_id
     AND TRIM(coa.account_code) = TRIM(m.code)
     AND coa.is_active = true
     AND coa.account_name <> m.name;

  GET DIAGNOSTICS v_bulk_aligned = ROW_COUNT;
  RAISE NOTICE 'Step 3: bulk-aligned % COA names to master', v_bulk_aligned;

  -- ==========================================================================
  -- Step 4: Verify zero active-row duplicates remain, then add the safety rail
  -- ==========================================================================
  SELECT COUNT(*)
    INTO v_active_dupes
    FROM (
      SELECT business_entity_id, TRIM(account_code) AS code
        FROM public.chart_of_accounts
       WHERE agency_id = v_agency_id
         AND is_active = true
       GROUP BY 1, 2
      HAVING COUNT(*) > 1
    ) x;

  IF v_active_dupes > 0 THEN
    RAISE EXCEPTION 'Cannot add UNIQUE rail: % active-row (business_entity_id, account_code) duplicate(s) still exist', v_active_dupes;
  END IF;

  -- The safety rail. Partial index: only enforces uniqueness on active rows,
  -- so inactive dupes (Phase 6 cleanup targets) can coexist without blocking.
  CREATE UNIQUE INDEX IF NOT EXISTS uq_chart_of_accounts_active_entity_code
    ON public.chart_of_accounts (business_entity_id, account_code)
    WHERE is_active = true;

  RAISE NOTICE 'Step 4: safety rail (partial UNIQUE index) in place';

END $mig$;

-- Final verification — should return zero rows if everything worked
DO $verify$
DECLARE
  v_remaining_mismatches INT;
BEGIN
  SELECT COUNT(*)
    INTO v_remaining_mismatches
    FROM public.chart_of_accounts coa
    JOIN public.account_master_codes m
      ON m.agency_id = coa.agency_id AND TRIM(m.code) = TRIM(coa.account_code)
   WHERE coa.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND coa.is_active = true
     AND coa.account_name <> m.name;

  RAISE NOTICE 'Verification: % remaining active name mismatches vs master (should be 0)', v_remaining_mismatches;
END $verify$;
