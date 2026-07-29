-- ============================================================================
-- Rebuild broken personal CC journal entries (Jan-Mar 2026)
-- ============================================================================
-- Scope: Capital One 7435 (Jan-Mar) + US Bank Personal CC 8847 (Jan-Feb).
-- Broken shape:
--   - JE header + all lines on b2222222 (agency) instead of b3333333 (personal)
--   - Lines hit COA-SUSP or COA-018 instead of proper personal expense accounts
--   - For charges: debit/credit sides inverted
-- Fix: DELETE existing lines, UPDATE JE header (entity + status),
--      INSERT correct 2-line pair based on merchant-pattern classifier.
--
-- Also handles ~9 lines that were correctly categorized but wrong-entity
-- (e.g. Feb-Mar Discretionary posted to b2222222).
-- ============================================================================

-- Step 1: Build a helper function for merchant → account_code mapping.
-- Positive amount = charge; negative amount = payment/refund/rewards.
CREATE OR REPLACE FUNCTION public.classify_personal_cc_txn(
  p_description text,
  p_amount      numeric
) RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $fn$
DECLARE
  d text := UPPER(COALESCE(p_description,''));
BEGIN
  -- Negative amounts: payment or refund or reward
  IF p_amount < 0 THEN
    -- Bank payment to card → Internal Transfer
    IF d LIKE '%CAPITAL ONE ONLINE PYMT%'
       OR d LIKE '%PAYMENT - THANK YOU%'
       OR d LIKE '%AUTOMATIC PAYMENT%'
       OR d LIKE '%ONLINE PAYMENT%'
       OR d LIKE '%MOBILE PAYMENT%'
       OR d LIKE '%PYMT RECEIVED%'
    THEN RETURN 'COA-PERSONAL-9990'; END IF;
    -- Cash back / rewards → Credit Card Rewards contra-expense
    IF d LIKE '%CASH BACK%' OR d LIKE '%REWARD%' OR d LIKE '%CREDIT ADJUSTMENT%' OR d LIKE '%CREDIT BALANCE%'
    THEN RETURN 'COA-PERSONAL-9820'; END IF;
    -- Merchant refunds → offset to same expense category (recurse with positive)
    RETURN public.classify_personal_cc_txn(p_description, ABS(p_amount));
  END IF;

  -- Positive amounts: charges

  -- Personal Insurance (State Farm auto/home/life on personal card)
  IF d LIKE '%STATE FARM INSURANCE%'
     OR d LIKE '%STATE FARM AUTO%'
     OR d LIKE '%STATE FARM MUTUAL%'
  THEN RETURN 'COA-PERSONAL-9600'; END IF;

  -- Groceries
  IF d LIKE '%HEB%' OR d LIKE '%H-E-B%'
     OR d LIKE '%SAM''S CLUB%' OR d LIKE '%SAMS CLUB%' OR d LIKE '%SAMSCLUB%'
     OR d LIKE '%WALMART GROCERY%' OR d LIKE '%KROGER%' OR d LIKE '%TRADER JOE%'
     OR d LIKE '%COSTCO%' OR d LIKE '%WHOLE FOODS%' OR d LIKE '%SPROUTS%'
     OR d LIKE '%ALDI%'
  THEN RETURN 'COA-PERSONAL-9200'; END IF;

  -- Kids (activities, sports, cheer, karate, camps)
  IF d LIKE '%TAEKW%' OR d LIKE '%KARATE%'
     OR d LIKE '%CHAMPIONS CHEER%' OR d LIKE '%CHEER GYM%'
     OR d LIKE '%DANCE STUDIO%'
     OR d LIKE '%YMCA%'
  THEN RETURN 'COA-PERSONAL-9400'; END IF;

  -- Medical & Health (doctors, dentists, pharmacies, optical, wellness)
  IF d LIKE '%PERIODONTIC%' OR d LIKE '%DENTAL%' OR d LIKE '%DENTIS%'
     OR d LIKE '%MYEYEDR%' OR d LIKE '%EYE DR%' OR d LIKE '%OPTOMETR%' OR d LIKE '%OPHTHALMO%'
     OR d LIKE '%1 NATURAL WAY%'
     OR d LIKE '%CVS%' OR d LIKE '%WALGREENS%' OR d LIKE '%PHARMACY%'
     OR d LIKE '%HOSPITAL%' OR d LIKE '%CLINIC%' OR d LIKE '%MEDICAL%'
     OR d LIKE '%URGENT CARE%' OR d LIKE '%DERMATOLOG%' OR d LIKE '%CARDIOLOG%'
  THEN RETURN 'COA-PERSONAL-9500'; END IF;

  -- Home Maintenance (yard, home services, repairs)
  IF d LIKE '%CINCH HOME%' OR d LIKE '%LAWN SERVICE%' OR d LIKE '%LAWN CARE%'
     OR d LIKE '%HOME DEPOT%' OR d LIKE '%LOWES%' OR d LIKE '%ACE HARDWARE%'
     OR d LIKE '%TRUGREEN%' OR d LIKE '%PEST CONTROL%'
     OR d LIKE '%PLUMB%' OR d LIKE '%HVAC%' OR d LIKE '%A/C REPAIR%'
  THEN RETURN 'COA-PERSONAL-9120'; END IF;

  -- Home Utilities (electric, gas, water, trash, internet, phone)
  IF d LIKE '%REPUBLIC SERVICES%' OR d LIKE '%WASTE MANAGE%'
     OR d LIKE '%CPS ENERGY%' OR d LIKE '%SAWS%' OR d LIKE '%SAN ANTONIO WATER%'
     OR d LIKE '%SPECTRUM%' OR d LIKE '%GOOGLE FIBER%' OR d LIKE '%ATT INTERNET%'
     OR d LIKE '%AT&T%' OR d LIKE '%T-MOBILE%' OR d LIKE '%VERIZON%'
     OR d LIKE '%ELECTRIC%' OR d LIKE '%UTILITY%'
  THEN RETURN 'COA-PERSONAL-9110'; END IF;

  -- Auto Fuel
  IF d LIKE '%SHELL%' OR d LIKE '%CHEVRON%' OR d LIKE '%EXXON%'
     OR d LIKE '%VALERO%' OR d LIKE '%QUIKTRIP%' OR d LIKE '%BUC-EE%' OR d LIKE '%BUCEE%'
     OR d LIKE '%COSTCO GAS%' OR d LIKE '%SAM''S FUEL%' OR d LIKE '%SAMS FUEL%'
     OR d LIKE '%HEB FUEL%' OR d LIKE '%CIRCLE K%'
  THEN RETURN 'COA-PERSONAL-9300'; END IF;

  -- Auto Maintenance (registration, repair, oil change)
  IF d LIKE '%BEXAR VEHREG%' OR d LIKE '%DMV%' OR d LIKE '%VEHICLE REG%'
     OR d LIKE '%JIFFY LUBE%' OR d LIKE '%FIRESTONE%' OR d LIKE '%DISCOUNT TIRE%'
     OR d LIKE '%OIL CHANGE%' OR d LIKE '%AUTO REPAIR%' OR d LIKE '%CAR WASH%'
  THEN RETURN 'COA-PERSONAL-9320'; END IF;

  -- Bank/CC Fees
  IF d LIKE '%LATE FEE%' OR d LIKE '%INTEREST CHARGE%' OR d LIKE '%FINANCE CHARGE%'
     OR d LIKE '%ANNUAL FEE%' OR d LIKE '%OVERLIMIT%'
  THEN RETURN 'COA-PERSONAL-9620'; END IF;

  -- Business expenses on personal card (owed back)
  IF d LIKE '%BUCK AND DOE%' OR d LIKE '%BUCK & DOE%'
  THEN RETURN 'COA-PERSONAL-9971'; END IF;

  -- Default: Discretionary (Amazon, Google, Netflix, entertainment, pets, misc)
  RETURN 'COA-PERSONAL-9800';
END;
$fn$;

COMMENT ON FUNCTION public.classify_personal_cc_txn(text,numeric) IS
  'Maps personal credit-card transaction description+amount to target COA account_code. '
  'Positive amount = charge; negative = payment/refund/reward. '
  'Built 2026-07-28 to backfill broken Jan-Mar personal CC journal entries.';

-- Step 2: Rebuild the broken JEs.
DO $rebuild$
DECLARE
  v_agency_id  uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_entity_id  uuid := 'b3333333-3333-3333-3333-333333333333';
  v_agency_ent uuid := 'b2222222-2222-2222-2222-222222222222';
  r record;
  v_target_code text;
  v_dr_acct uuid;
  v_cr_acct uuid;
  v_cc_acct uuid;
  v_dr_amt numeric;
  v_cr_amt numeric;
  n_rebuilt int := 0;
  n_relocated int := 0;
BEGIN
  -- 2a. Rebuild JEs that are broken (hit COA-SUSP, COA-018, or wrong entity)
  FOR r IN
    SELECT DISTINCT
      ct.id AS ct_id,
      ct.transaction_date,
      ct.amount,
      ct.description,
      ct.journal_entry_id AS je_id,
      ca.chart_account_id AS cc_acct_id,
      ca.account_number_last4 AS card_last4
    FROM public.credit_transactions ct
    JOIN public.credit_accounts ca ON ca.id = ct.credit_account_id
    WHERE ca.business_entity_id = v_entity_id
      AND ct.journal_entry_id IS NOT NULL
      AND (
        (ca.account_number_last4 = '7435' AND ct.transaction_date >= '2026-01-01' AND ct.transaction_date <= '2026-03-31')
        OR
        (ca.account_number_last4 = '8847' AND ct.transaction_date >= '2026-01-01' AND ct.transaction_date <= '2026-02-28')
      )
      AND EXISTS (
        SELECT 1 FROM public.journal_lines jl
        LEFT JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
        WHERE jl.journal_entry_id = ct.journal_entry_id
          AND (
            coa.account_code IN ('COA-SUSP','COA-018')
            OR jl.business_entity_id = v_agency_ent
          )
      )
  LOOP
    -- Classify to target COA account_code
    v_target_code := public.classify_personal_cc_txn(r.description, r.amount);

    SELECT id INTO v_dr_acct
    FROM public.chart_of_accounts
    WHERE agency_id = v_agency_id AND account_code = v_target_code;

    IF v_dr_acct IS NULL THEN
      RAISE EXCEPTION 'Classifier returned unknown account_code=% for description=%', v_target_code, r.description;
    END IF;

    v_cc_acct := r.cc_acct_id;

    -- For charges (amount > 0): DR expense/asset  CR CC-liability
    -- For payments/refunds (amount < 0): DR CC-liability  CR classified account
    IF r.amount >= 0 THEN
      v_dr_amt := r.amount;
      v_cr_amt := r.amount;
      -- DR = target expense account, CR = CC liability
      DELETE FROM public.journal_lines WHERE journal_entry_id = r.je_id;
      INSERT INTO public.journal_lines
        (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES
        (r.je_id, v_agency_id, v_dr_acct,   v_dr_amt, 0,        r.description, v_entity_id),
        (r.je_id, v_agency_id, v_cc_acct,   0,        v_cr_amt, r.description, v_entity_id);
    ELSE
      v_dr_amt := ABS(r.amount);
      v_cr_amt := ABS(r.amount);
      -- DR = CC liability (reduce), CR = target offset account
      DELETE FROM public.journal_lines WHERE journal_entry_id = r.je_id;
      INSERT INTO public.journal_lines
        (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES
        (r.je_id, v_agency_id, v_cc_acct,  v_dr_amt, 0,        r.description, v_entity_id),
        (r.je_id, v_agency_id, v_dr_acct,  0,        v_cr_amt, r.description, v_entity_id);
    END IF;

    -- Update JE header
    UPDATE public.journal_entries
    SET business_entity_id  = v_entity_id,
        classification_status = 'classified',
        suspense_reason       = NULL,
        classified_by         = 'claude-2026-07-28-personal-cc-fix',
        classified_at         = NOW()
    WHERE id = r.je_id;

    n_rebuilt := n_rebuilt + 1;
  END LOOP;

  RAISE NOTICE 'Rebuilt % broken JEs', n_rebuilt;

  -- 2b. Relocate wrong-entity (but structurally correct) JEs from b2222222 → b3333333
  -- These are transactions where the JE already hits proper personal expense/asset accounts
  -- but the line business_entity_id got stamped agency instead of personal.
  UPDATE public.journal_lines jl
  SET business_entity_id = v_entity_id
  WHERE jl.business_entity_id = v_agency_ent
    AND jl.journal_entry_id IN (
      SELECT ct.journal_entry_id
      FROM public.credit_transactions ct
      JOIN public.credit_accounts ca ON ca.id = ct.credit_account_id
      WHERE ca.business_entity_id = v_entity_id
        AND ct.journal_entry_id IS NOT NULL
    )
    AND EXISTS (
      SELECT 1 FROM public.chart_of_accounts coa
      WHERE coa.id = jl.account_id
        AND coa.account_code LIKE 'COA-PERSONAL-%'
    );

  GET DIAGNOSTICS n_relocated = ROW_COUNT;
  RAISE NOTICE 'Relocated % lines from agency entity to personal entity', n_relocated;

  -- 2c. Update matching JE headers to personal entity if all their lines are now personal
  UPDATE public.journal_entries je
  SET business_entity_id = v_entity_id
  WHERE je.business_entity_id = v_agency_ent
    AND je.id IN (
      SELECT ct.journal_entry_id FROM public.credit_transactions ct
      JOIN public.credit_accounts ca ON ca.id = ct.credit_account_id
      WHERE ca.business_entity_id = v_entity_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.journal_lines jl
      WHERE jl.journal_entry_id = je.id
        AND jl.business_entity_id != v_entity_id
    );

END $rebuild$;
