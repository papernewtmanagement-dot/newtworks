DROP FUNCTION IF EXISTS public.legacy_post_staged_batch(UUID, INT, INT);

CREATE OR REPLACE FUNCTION public.legacy_post_staged_batch(
  p_agency_id UUID, p_fiscal_year INT, p_batch_size INT DEFAULT 500
) RETURNS TABLE (
  posted_count INT, zero_skipped INT, errored INT, remaining INT,
  total_debits NUMERIC, total_credits NUMERIC
) LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_susp_id UUID; v_posted INT := 0; v_zero INT := 0; v_err INT := 0;
  v_debits NUMERIC := 0; v_credits NUMERIC := 0;
  r RECORD; v_je_id UUID; v_acct_id UUID; v_d NUMERIC; v_c NUMERIC;
BEGIN
  SELECT id INTO v_susp_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = 'books_historical' AND account_code = 'COA-SUSP';
  IF v_susp_id IS NULL THEN RAISE EXCEPTION 'COA-SUSP account not found for agency %', p_agency_id; END IF;

  FOR r IN
    SELECT * FROM legacy_import_staging
    WHERE agency_id = p_agency_id AND fiscal_year = p_fiscal_year AND posted = false
    ORDER BY entry_date, id LIMIT p_batch_size FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      SELECT id INTO v_acct_id FROM chart_of_accounts
        WHERE agency_id = p_agency_id AND chart_namespace = 'books_historical' AND account_name = r.account_name;
      IF v_acct_id IS NULL THEN
        UPDATE legacy_import_staging SET error_msg = 'account_not_found: ' || r.account_name WHERE id = r.id;
        v_err := v_err + 1; CONTINUE;
      END IF;
      IF r.amount = 0 THEN
        INSERT INTO journal_entries (agency_id, entry_date, entry_type, description, memo, source, created_by)
        VALUES (p_agency_id, r.entry_date, 'gl_import_zero', r.description, r.memo, r.source_tag, 'books_historical_loader')
        RETURNING id INTO v_je_id;
        UPDATE legacy_import_staging SET posted = true, posted_je_id = v_je_id, posted_at = now(),
          error_msg = 'zero_amount: reference entry, no GL impact' WHERE id = r.id;
        v_zero := v_zero + 1; CONTINUE;
      END IF;
      IF r.amount >= 0 THEN v_d := r.amount; v_c := 0; ELSE v_d := 0; v_c := -r.amount; END IF;
      INSERT INTO journal_entries (agency_id, entry_date, entry_type, description, memo, source, created_by)
      VALUES (p_agency_id, r.entry_date, 'gl_import', r.description, r.memo, r.source_tag, 'books_historical_loader')
      RETURNING id INTO v_je_id;
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description) VALUES
        (v_je_id, p_agency_id, v_acct_id, v_d, v_c, NULL),
        (v_je_id, p_agency_id, v_susp_id, v_c, v_d, NULL);
      UPDATE legacy_import_staging SET posted = true, posted_je_id = v_je_id, posted_at = now(),
        error_msg = NULL WHERE id = r.id;
      v_posted := v_posted + 1;
      v_debits := v_debits + v_d + v_c; v_credits := v_credits + v_c + v_d;
    EXCEPTION WHEN OTHERS THEN
      UPDATE legacy_import_staging SET error_msg = SQLERRM WHERE id = r.id; v_err := v_err + 1;
    END;
  END LOOP;
  RETURN QUERY SELECT v_posted, v_zero, v_err,
    (SELECT COUNT(*)::INT FROM legacy_import_staging WHERE agency_id = p_agency_id AND fiscal_year = p_fiscal_year AND posted = false),
    v_debits, v_credits;
END; $$;

GRANT EXECUTE ON FUNCTION public.legacy_post_staged_batch(UUID, INT, INT) TO authenticated, service_role;
