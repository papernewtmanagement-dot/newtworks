-- ============================================================================
-- Fix 5 stray AMEX Amazon JEs misclassified to Tithe & Charitable
-- ============================================================================
-- 5 JEs from Feb + Jun 2026 mistakenly landed DR COA-PERSONAL-9700 Tithe & Charitable
-- on PaperNewt entity. Correct pattern for un-triaged Amazon-on-AMEX-Discretionary
-- charges is Suspense on agency entity (matches 84 other pending Amazon-on-AMEX rows).
-- Move them into that queue for proper vendor-walk classification.
-- ============================================================================

DO $fix$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_agency_ent uuid := 'b2222222-2222-2222-2222-222222222222';
  v_susp uuid;
  v_amex uuid;
  r record;
  n_fixed int := 0;
BEGIN
  SELECT id INTO v_susp FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND account_code='COA-SUSP';
  SELECT id INTO v_amex FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND account_code='COA-009';

  IF v_susp IS NULL OR v_amex IS NULL THEN
    RAISE EXCEPTION 'Missing COA: susp=% amex=%', v_susp, v_amex;
  END IF;

  FOR r IN
    SELECT DISTINCT je.id, je.description
    FROM public.journal_entries je
    JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE je.agency_id = v_agency_id
      AND je.source = 'cc_gl_writer'
      AND je.description ~* '(AMAZON|AMZN)'
      AND coa.account_code = 'COA-PERSONAL-9700'
  LOOP
    -- Get the JE amount from existing debit line
    DECLARE
      v_amt numeric;
    BEGIN
      SELECT debit INTO v_amt FROM public.journal_lines
      WHERE journal_entry_id = r.id AND debit > 0
      LIMIT 1;

      DELETE FROM public.journal_lines WHERE journal_entry_id = r.id;
      INSERT INTO public.journal_lines
        (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
      VALUES
        (r.id, v_agency_id, v_susp, v_amt, 0,     r.description, v_agency_ent),
        (r.id, v_agency_id, v_amex, 0,     v_amt, r.description, v_agency_ent);

      UPDATE public.journal_entries
      SET business_entity_id  = v_agency_ent,
          classification_status = 'pending_review',
          suspense_reason       = 'Amazon-on-AMEX pending vendor-walk classification (was mis-classified to Tithe)',
          classified_by         = 'claude-2026-07-28-amex-amazon-fix',
          classified_at         = NOW()
      WHERE id = r.id;

      n_fixed := n_fixed + 1;
    END;
  END LOOP;

  RAISE NOTICE 'Moved % AMEX Amazon JEs from Tithe to Suspense (agency entity)', n_fixed;
END $fix$;
