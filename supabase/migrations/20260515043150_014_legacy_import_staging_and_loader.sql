-- Staging table to hold parsed GL transactions before posting
CREATE TABLE IF NOT EXISTS legacy_import_staging (
  id BIGSERIAL PRIMARY KEY,
  agency_id UUID NOT NULL,
  fiscal_year INT NOT NULL,
  account_name TEXT NOT NULL,
  entry_date DATE NOT NULL,
  amount NUMERIC(15,2) NOT NULL,
  description TEXT,
  memo TEXT,
  source_tag TEXT NOT NULL DEFAULT 'books_historical_import',
  posted BOOLEAN NOT NULL DEFAULT false,
  posted_je_id UUID,
  posted_at TIMESTAMPTZ,
  error_msg TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS books_historical_staging_unposted_idx ON legacy_import_staging(agency_id, fiscal_year, posted);

-- Loader function: posts up to `batch_size` unposted rows from staging into
-- journal_entries + journal_lines (2 lines per transaction: account + Suspense).
CREATE OR REPLACE FUNCTION public.legacy_post_staged_batch(
  p_agency_id UUID,
  p_fiscal_year INT,
  p_batch_size INT DEFAULT 500
) RETURNS TABLE (
  posted_count INT,
  remaining INT,
  total_debits NUMERIC,
  total_credits NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_susp_id UUID;
  v_posted INT := 0;
  v_debits NUMERIC := 0;
  v_credits NUMERIC := 0;
  r RECORD;
  v_je_id UUID;
  v_acct_id UUID;
  v_d NUMERIC;
  v_c NUMERIC;
BEGIN
  -- Resolve suspense account once
  SELECT id INTO v_susp_id
  FROM chart_of_accounts
  WHERE agency_id = p_agency_id
    AND chart_namespace = 'books_historical'
    AND account_code = 'COA-SUSP';
  IF v_susp_id IS NULL THEN
    RAISE EXCEPTION 'COA-SUSP account not found in chart_of_accounts for agency %', p_agency_id;
  END IF;

  -- Process each unposted staged row, ordered by date then id for deterministic ordering
  FOR r IN
    SELECT * FROM legacy_import_staging
    WHERE agency_id = p_agency_id
      AND fiscal_year = p_fiscal_year
      AND posted = false
    ORDER BY entry_date, id
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      -- Look up the txn's account in the legacy-source namespace
      SELECT id INTO v_acct_id
      FROM chart_of_accounts
      WHERE agency_id = p_agency_id
        AND chart_namespace = 'books_historical'
        AND account_name = r.account_name;
      IF v_acct_id IS NULL THEN
        UPDATE legacy_import_staging
          SET error_msg = 'account_not_found: ' || r.account_name
          WHERE id = r.id;
        CONTINUE;
      END IF;

      -- Determine debit/credit direction
      IF r.amount >= 0 THEN
        v_d := r.amount; v_c := 0;
      ELSE
        v_d := 0; v_c := -r.amount;
      END IF;

      -- Insert journal entry
      INSERT INTO journal_entries (agency_id, entry_date, entry_type, description, memo, source, created_by)
      VALUES (p_agency_id, r.entry_date, 'gl_import', r.description, r.memo, r.source_tag, 'books_historical_loader')
      RETURNING id INTO v_je_id;

      -- Insert the two lines
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description) VALUES
        (v_je_id, p_agency_id, v_acct_id, v_d, v_c, NULL),
        (v_je_id, p_agency_id, v_susp_id, v_c, v_d, NULL);  -- mirror: account dr -> suspense cr and vice versa

      -- Mark staging row as posted
      UPDATE legacy_import_staging
        SET posted = true, posted_je_id = v_je_id, posted_at = now(), error_msg = NULL
        WHERE id = r.id;

      v_posted := v_posted + 1;
      v_debits := v_debits + v_d + v_c;   -- both lines contribute one to each side
      v_credits := v_credits + v_c + v_d;
    EXCEPTION WHEN OTHERS THEN
      UPDATE legacy_import_staging
        SET error_msg = SQLERRM
        WHERE id = r.id;
    END;
  END LOOP;

  -- Compose return
  RETURN QUERY
  SELECT
    v_posted,
    (SELECT COUNT(*)::INT FROM legacy_import_staging WHERE agency_id = p_agency_id AND fiscal_year = p_fiscal_year AND posted = false),
    v_debits,
    v_credits;
END;
$$;

-- Grant
GRANT EXECUTE ON FUNCTION public.legacy_post_staged_batch(UUID, INT, INT) TO authenticated, service_role;
