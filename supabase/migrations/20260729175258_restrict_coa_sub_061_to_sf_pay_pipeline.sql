-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 17:52:58 UTC (ledger name: restrict_coa_sub_061_to_sf_pay_pipeline) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729175258.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Structural guard: COA-SUB-061 "US BANK" can only be written to by the SF pay statement pipeline
-- (gl_entry_writer with classified_by='comp_map', or reference_number starting with 'comp_recap:').
-- Any other write attempt is rejected at insert/update time.

CREATE OR REPLACE FUNCTION public.enforce_us_bank_alliance_account_source()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_restricted_account_id uuid;
  v_je_source text;
  v_je_classified_by text;
  v_je_reference_number text;
BEGIN
  SELECT id INTO v_restricted_account_id
  FROM public.chart_of_accounts
  WHERE agency_id = NEW.agency_id
    AND account_code = 'COA-SUB-061'
  LIMIT 1;

  IF v_restricted_account_id IS NULL OR NEW.account_id != v_restricted_account_id THEN
    RETURN NEW;
  END IF;

  SELECT source, classified_by, reference_number
  INTO v_je_source, v_je_classified_by, v_je_reference_number
  FROM public.journal_entries
  WHERE id = NEW.journal_entry_id;

  IF v_je_source = 'gl_entry_writer'
     AND (v_je_classified_by = 'comp_map'
          OR v_je_reference_number LIKE 'comp_recap:%') THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'COA-SUB-061 US BANK alliance income is restricted: only SF pay statement pipeline can write to this account (gl_entry_writer + comp_map). Attempted write from source=%, classified_by=%, reference_number=%',
    v_je_source, v_je_classified_by, v_je_reference_number;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_us_bank_alliance_source ON public.journal_lines;
CREATE TRIGGER trg_enforce_us_bank_alliance_source
BEFORE INSERT OR UPDATE ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.enforce_us_bank_alliance_account_source();
