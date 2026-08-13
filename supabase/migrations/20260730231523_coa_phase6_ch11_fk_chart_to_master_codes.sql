-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 23:15:23 UTC (ledger name: coa_phase6_ch11_fk_chart_to_master_codes) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730231523.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- CoA Phase 6 · Chunk 11 · Migration C
-- Add composite foreign key: chart_of_accounts.(agency_id, account_code) → account_master_codes.(agency_id, code).

-- ── Section 1 · Normalize account_master_codes.code (strip any padding) ─────────
UPDATE public.account_master_codes
SET code = TRIM(code)
WHERE code <> TRIM(code);

-- ── Section 2 · Change type CHAR(4) → TEXT ──────────────────────────────────────
ALTER TABLE public.account_master_codes
  ALTER COLUMN code TYPE TEXT USING TRIM(code);

-- ── Section 3 · Preserve the length-4 invariant as a CHECK ──────────────────────
ALTER TABLE public.account_master_codes
  DROP CONSTRAINT IF EXISTS account_master_codes_code_len_check;
ALTER TABLE public.account_master_codes
  ADD CONSTRAINT account_master_codes_code_len_check
  CHECK (LENGTH(code) = 4);

-- ── Section 4 · Normalize chart_of_accounts.account_code (defensive TRIM) ───────
UPDATE public.chart_of_accounts
SET account_code = TRIM(account_code)
WHERE account_code IS NOT NULL AND account_code <> TRIM(account_code);

-- ── Section 5 · Supporting index for FK check + parent lookups ──────────────────
CREATE INDEX IF NOT EXISTS idx_chart_of_accounts_agency_code
  ON public.chart_of_accounts (agency_id, account_code);

-- ── Section 6 · Add the composite FK constraint ─────────────────────────────────
ALTER TABLE public.chart_of_accounts
  DROP CONSTRAINT IF EXISTS chart_of_accounts_master_code_fkey;
ALTER TABLE public.chart_of_accounts
  ADD CONSTRAINT chart_of_accounts_master_code_fkey
  FOREIGN KEY (agency_id, account_code)
  REFERENCES public.account_master_codes (agency_id, code)
  ON UPDATE CASCADE
  ON DELETE RESTRICT;

-- ── Section 7 · Verification ────────────────────────────────────────────────────
DO $$
DECLARE
  v_master_type TEXT;
  v_fk_count INTEGER;
  v_orphans INTEGER;
BEGIN
  SELECT data_type INTO v_master_type FROM information_schema.columns
    WHERE table_schema='public' AND table_name='account_master_codes' AND column_name='code';
  SELECT COUNT(*) INTO v_fk_count FROM information_schema.table_constraints
    WHERE table_schema='public' AND table_name='chart_of_accounts'
      AND constraint_type='FOREIGN KEY' AND constraint_name = 'chart_of_accounts_master_code_fkey';
  SELECT COUNT(*) INTO v_orphans FROM public.chart_of_accounts coa
    WHERE coa.agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND NOT EXISTS (SELECT 1 FROM public.account_master_codes amc
        WHERE amc.agency_id = coa.agency_id AND amc.code = coa.account_code);

  IF v_master_type <> 'text' THEN RAISE EXCEPTION 'Ch11 verify: expected TEXT, got %', v_master_type; END IF;
  IF v_fk_count <> 1 THEN RAISE EXCEPTION 'Ch11 verify: FK not present (%)', v_fk_count; END IF;
  IF v_orphans <> 0 THEN RAISE EXCEPTION 'Ch11 verify: % orphans', v_orphans; END IF;

  RAISE NOTICE 'Ch11 done: master.code is TEXT, FK enforced, 0 orphans';
END;
$$;
