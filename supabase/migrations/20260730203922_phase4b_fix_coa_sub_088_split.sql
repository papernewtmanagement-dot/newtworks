-- Fix: move the 6 unlabeled COA-SUB-088 reimbursements from 6710 to 0003 Unclassified Expense.
-- Keep the 2 known team-licensing lines ($79 Stephanie 6/12, $311.26 Jason 6/22) at 6710.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pss uuid := 'b2222222-2222-2222-2222-222222222222';
  v_6710 uuid;
  v_0003 uuid;
  v_recl_id uuid := gen_random_uuid();
  v_count integer;
  v_total numeric;
BEGIN
  SELECT id INTO v_6710
  FROM public.chart_of_accounts
  WHERE agency_id = v_agency AND business_entity_id = v_pss AND account_code = '6710' AND is_active = true;

  SELECT id INTO v_0003
  FROM public.chart_of_accounts
  WHERE agency_id = v_agency AND business_entity_id = v_pss AND account_code = '0003' AND is_active = true;

  IF v_6710 IS NULL OR v_0003 IS NULL THEN
    RAISE EXCEPTION 'Missing accounts: 6710=% 0003=%', v_6710, v_0003;
  END IF;

  -- Identify the 6 unlabeled lines by explicit ID list (from diagnostic pull)
  WITH target_ids AS (
    SELECT unnest(ARRAY[
      '053805fd-190a-434a-a052-d1e73c106a94'::uuid,  -- 3/6  $238.00
      '0e3029f6-9c6c-4f86-8e7f-be953f5a2de7'::uuid,  -- 4/10 $102.23
      '946f0acb-65e6-4e9f-8841-04289b1c5227'::uuid,  -- 7/17 $61.13
      'cb577113-4313-4e3e-a547-82bd2dc84dc6'::uuid,  -- 7/17 $61.13 dup
      'dc0ce731-78b9-4540-9fb6-e2b033515db0'::uuid,  -- 7/17 -$61.13 reversal
      'd68a3e63-4971-4a34-9440-5402e64e41e7'::uuid   -- 7/31 $879.26
    ]) AS jl_id
  )
  SELECT COUNT(*), COALESCE(SUM(GREATEST(jl.debit, jl.credit)), 0)
    INTO v_count, v_total
  FROM public.journal_lines jl
  JOIN target_ids t ON t.jl_id = jl.id
  WHERE jl.agency_id = v_agency;

  INSERT INTO public.account_reclassifications
    (id, agency_id, from_account_id, to_account_id, filter_description,
     journal_line_count, total_amount, performed_at, performed_by, notes)
  VALUES
    (v_recl_id, v_agency, v_6710, v_0003,
     'Phase 4 fix: 6 unlabeled COA-SUB-088 reimbursements → 0003 (2 known team-licensing lines stay at 6710)',
     v_count, v_total, NOW(), 'phase4_coa_reorg',
     'Split correction: initial move swept all 8 lines to 6710; this reverses the 6 unlabeled to 0003.');

  UPDATE public.journal_lines
  SET account_id = v_0003,
      reclassification_id = v_recl_id
  WHERE id IN (
    '053805fd-190a-434a-a052-d1e73c106a94'::uuid,
    '0e3029f6-9c6c-4f86-8e7f-be953f5a2de7'::uuid,
    '946f0acb-65e6-4e9f-8841-04289b1c5227'::uuid,
    'cb577113-4313-4e3e-a547-82bd2dc84dc6'::uuid,
    'dc0ce731-78b9-4540-9fb6-e2b033515db0'::uuid,
    'd68a3e63-4971-4a34-9440-5402e64e41e7'::uuid
  );
END $$;
