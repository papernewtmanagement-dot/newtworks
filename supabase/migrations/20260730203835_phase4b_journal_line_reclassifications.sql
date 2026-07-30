-- Phase 4b: Move journal lines from legacy COA-SUB-###/COA-PN-###/6311/6315 to clean master-code accounts.
-- Logs every batch to account_reclassifications and stamps journal_lines.original_account_id + reclassification_id.

-- ============================================================================
-- Helper: reclassify all lines from one account to another, with audit log.
-- Optional description filter for splits (COA-SUB-007, COA-SUB-088).
-- ============================================================================
CREATE OR REPLACE FUNCTION public._phase4_reclassify(
  p_agency uuid,
  p_from_entity_name text,
  p_from_code text,
  p_to_entity_name text,
  p_to_code text,
  p_notes text,
  p_desc_ilike text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_from_id uuid;
  v_to_id uuid;
  v_recl_id uuid := gen_random_uuid();
  v_count integer;
  v_total numeric;
BEGIN
  SELECT coa.id INTO v_from_id
  FROM public.chart_of_accounts coa
  JOIN public.business_entities be ON be.id = coa.business_entity_id
  WHERE coa.agency_id = p_agency AND be.name = p_from_entity_name AND coa.account_code = p_from_code;

  SELECT coa.id INTO v_to_id
  FROM public.chart_of_accounts coa
  JOIN public.business_entities be ON be.id = coa.business_entity_id
  WHERE coa.agency_id = p_agency AND be.name = p_to_entity_name AND coa.account_code = p_to_code
    AND coa.is_active = true;

  IF v_from_id IS NULL THEN
    RAISE EXCEPTION 'Source account not found: entity=% code=%', p_from_entity_name, p_from_code;
  END IF;
  IF v_to_id IS NULL THEN
    RAISE EXCEPTION 'Destination account not found: entity=% code=%', p_to_entity_name, p_to_code;
  END IF;

  SELECT COUNT(*), COALESCE(SUM(GREATEST(debit, credit)), 0)
    INTO v_count, v_total
  FROM public.journal_lines
  WHERE agency_id = p_agency AND account_id = v_from_id
    AND (p_desc_ilike IS NULL OR description ILIKE p_desc_ilike);

  IF v_count = 0 THEN
    RETURN 0;
  END IF;

  INSERT INTO public.account_reclassifications
    (id, agency_id, from_account_id, to_account_id, filter_description,
     journal_line_count, total_amount, performed_at, performed_by, notes)
  VALUES
    (v_recl_id, p_agency, v_from_id, v_to_id,
     COALESCE('Phase 4: ' || p_from_code || ' → ' || p_to_code
              || CASE WHEN p_desc_ilike IS NOT NULL THEN ' (filter: '||p_desc_ilike||')' ELSE '' END, ''),
     v_count, v_total, NOW(), 'phase4_coa_reorg', p_notes);

  UPDATE public.journal_lines
  SET account_id = v_to_id,
      original_account_id = COALESCE(original_account_id, v_from_id),
      reclassification_id = v_recl_id
  WHERE agency_id = p_agency AND account_id = v_from_id
    AND (p_desc_ilike IS NULL OR description ILIKE p_desc_ilike);

  RETURN v_count;
END $$;

-- ============================================================================
-- INCOME MOVES (13 legacy income buckets → clean 4xxx PSS accounts)
-- ============================================================================
DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pss   text := 'Peter Story State Farm';
  v_pn    text := 'PaperNewt LLC';
BEGIN
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-057', v_pss, '4100', 'P&C New commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-058', v_pss, '4101', 'P&C Renewal commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-059', v_pss, '4110', 'Life New commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-060', v_pss, '4111', 'Life Renewal commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-061', v_pss, '4200', 'US Bank origination income consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-062', v_pss, '4120', 'Health New commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-063', v_pss, '4121', 'Health Renewal commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-065', v_pss, '4131', 'Pet Renewal commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-066', v_pss, '4020', 'SFVC commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-067', v_pss, '4021', 'IPSI Life commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-068', v_pss, '4022', 'Variable Life Servicing commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-069', v_pss, '4023', 'IPS Brokerage Trail commissions consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-082', v_pss, '4140', 'SF Bonuses consolidation');

  -- ============================================================================
  -- EXPENSE MOVES (clean 1-to-1)
  -- ============================================================================
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-001', v_pss, '6240', 'Building Maintenance → Repairs & Maintenance');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-002', v_pss, '6850', 'Business Travel consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-004', v_pss, '6160', 'Employee Relations consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-008', v_pss, '6860', 'Meals (50%) consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-010', v_pss, '6910', 'Office Expense → Office Supplies');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-012', v_pss, '6910', 'Office Supplies consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-014', v_pss, '6280', 'Security consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-017', v_pss, '6750', 'Books & Publications consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-023', v_pss, '6710', 'Dues & Licenses — Agent → License Renewal Fees');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-028', v_pss, '6320', 'Internet → Phone & Internet');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-029', v_pss, '6530', 'Legal & Accounting → Consulting & Professional Fees');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-031', v_pss, '6860', 'Meals (50%) duplicate bucket consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-037', v_pss, '6210', 'Rent & Lease consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-041', v_pss, '6320', 'Cell phone → Phone & Internet');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-046', v_pss, '6270', 'Home Office Internet → Home Office Reimbursement');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-048', v_pss, '6400', 'Ad Space → Advertising & Marketing');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-049', v_pss, '6400', 'Direct Mail → Advertising & Marketing');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-052', v_pss, '6410', 'Internet Leads consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-073', v_pss, '6710', 'Dues & Licenses — Team → License Renewal Fees');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-077', v_pss, '6110', 'Health Insurance Employees → Health Insurance — Staff');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-078', v_pss, '6010', 'Team payroll → Staff Wages (budget_category=team tag added below)');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-079', v_pss, '6180', 'Recruitment Costs consolidation');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-084', v_pss, '6941', 'Business auto loan payments → Interest Expense (provisional; CPA true-up at year-end)');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-086', v_pss, '6010', 'Growth payroll → Staff Wages (budget_category=growth tag added below)');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-090', v_pss, '3020', 'Personal-Discretionary on agency card → Owner Draws (commingling cleanup)');
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-091', v_pss, '3020', 'Personal-Insurance on agency card → Owner Draws (commingling cleanup)');

  -- ============================================================================
  -- PSS SaaS consolidation (6311 Claude.ai, 6315 Other Software → 6310)
  -- ============================================================================
  PERFORM public._phase4_reclassify(v_agency, v_pss, '6311', v_pss, '6310', 'Claude.ai subscription → Software & SaaS');
  PERFORM public._phase4_reclassify(v_agency, v_pss, '6315', v_pss, '6310', 'Other Software → Software & SaaS');

  -- ============================================================================
  -- COA-SUB-007 (12 lines mixed): 3-way split by description filter
  -- ============================================================================
  -- 5 mobile banking transfers to account 3977 (PaperNewt US Bank Business Checking)
  --   → 2902 Due to PaperNewt (intercompany liability)
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-007', v_pss, '2902',
    'Bank transfers to PN 3977 checking (intercompany)', '%Mobile Banking Transfer%104787443977%');
  -- 1 CC 8847 mobile banking payment (personal AMEX per open classifier bug)
  --   → 3020 Owner Draws
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-007', v_pss, '3020',
    'Personal AMEX 8847 payment on agency GL (classifier misroute) → Owner Draws', '%8847%Mobile Banking Payment%');
  -- Remaining lines (6 actual fuel charges: Shell, BIG'S) → 6810 Vehicle Expenses
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-007', v_pss, '6810',
    'Actual fuel charges → Vehicle Expenses (remainder of Gas/Oil/Lube bucket)');

  -- ============================================================================
  -- COA-SUB-088 (8 lines): NOTE — initial sweep moves all 8 to 6710; the
  -- follow-up migration phase4b_fix_coa_sub_088_split moves the 6 unlabeled
  -- lines to 0003 Unclassified Expense — Business.
  -- ============================================================================
  PERFORM public._phase4_reclassify(v_agency, v_pss, 'COA-SUB-088', v_pss, '6710',
    'Team licensing reimbursements (Stephanie 6/12, Jason 6/22) → License Renewal Fees. Fix migration follows to move 6 unlabeled lines to 0003.',
    NULL);
END $$;

-- ============================================================================
-- PaperNewt: COA-PN-002 unmapped Payroll Cash (74 lines) → 1050 US Bank Business Checking 3977
-- ============================================================================
DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pn text := 'PaperNewt LLC';
BEGIN
  PERFORM public._phase4_reclassify(v_agency, v_pn, 'COA-PN-002', v_pn, '1050',
    'Unmapped Payroll Cash → US Bank Business Checking (3977)');
END $$;

-- ============================================================================
-- PaperNewt: COA-PN-001 Payroll Costs (38 lines all labeled owner/officer/PN-direct)
-- → 6020 Owner W-2 Wages on PaperNewt.
-- Note: Leslie's W-2 lines may be lumped in here; year-end split to 6010 if needed.
-- ============================================================================
DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pn text := 'PaperNewt LLC';
BEGIN
  PERFORM public._phase4_reclassify(v_agency, v_pn, 'COA-PN-001', v_pn, '6020',
    'PaperNewt combined owner/officer/PN-direct W-2 payroll → 6020 (year-end CPA may split staff portion to 6010)');
END $$;

-- ============================================================================
-- Budget category tags for payroll: growth vs team
-- Tag every journal_line that originated in COA-SUB-078 (team) or COA-SUB-086 (growth)
-- ============================================================================
INSERT INTO public.transaction_tags (id, agency_id, journal_line_id, tag_key, tag_value, created_by)
SELECT gen_random_uuid(), jl.agency_id, jl.id, 'budget_category', 'team', 'phase4_coa_reorg'
FROM public.journal_lines jl
JOIN public.chart_of_accounts src ON src.id = jl.original_account_id
WHERE jl.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND src.account_code = 'COA-SUB-078';

INSERT INTO public.transaction_tags (id, agency_id, journal_line_id, tag_key, tag_value, created_by)
SELECT gen_random_uuid(), jl.agency_id, jl.id, 'budget_category', 'growth', 'phase4_coa_reorg'
FROM public.journal_lines jl
JOIN public.chart_of_accounts src ON src.id = jl.original_account_id
WHERE jl.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND src.account_code = 'COA-SUB-086';

-- ============================================================================
-- Drop the helper (single-use for this migration)
-- ============================================================================
DROP FUNCTION public._phase4_reclassify(uuid, text, text, text, text, text, text);
