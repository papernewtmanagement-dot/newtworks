-- CoA Phase 6 · Chunk 11 · Migration C
-- Add composite foreign key: chart_of_accounts.(agency_id, account_code) → account_master_codes.(agency_id, code).
--
-- This is the last structural piece of the CoA overhaul. Every active chart_of_accounts row
-- must correspond to a row in the master reference table. Enforcing this at the DB level
-- prevents future code drift (accidental typos, renames without master sync) that would
-- otherwise break P&L views and rollups.
--
-- Type reconciliation:
--   account_master_codes.code is currently CHAR(4) (fixed-width, space-padded).
--   chart_of_accounts.account_code is TEXT (no padding).
--   PostgreSQL composite FKs require type match. Cleanest fix: convert master.code to TEXT.
--   The CHAR(4) was an artifact of the initial master-table seed; TEXT + a CHECK on length
--   is functionally identical and eliminates space-padding traps.
--
-- Pre-flight state confirmed:
--   162 active COAs, all with a matching account_master_codes row (0 orphans via TRIM match)
--   0 active COAs where account_code length differs from 4
--   0 existing FKs pointing at account_master_codes (safe to change its PK column type)
--
-- Strategy:
--   (1) TRIM any padding on account_master_codes.code (defensive; CHAR(4) can carry spaces
--       if seeded from mixed sources).
--   (2) ALTER COLUMN code TYPE TEXT — rebuilds the PK index automatically.
--   (3) Add CHECK constraint enforcing length = 4 (preserves the semantic invariant that
--       CHAR(4) was giving us).
--   (4) TRIM any padding on chart_of_accounts.account_code (defensive; TEXT normally
--       has no padding but paranoid because we're about to hard-enforce equality).
--   (5) Add supporting index on chart_of_accounts.(agency_id, account_code) to keep
--       FK check + parent lookups efficient.
--   (6) Add the composite FK constraint chart_of_accounts_master_code_fkey with
--       ON UPDATE CASCADE / ON DELETE RESTRICT — renames flow through, deletes blocked.

BEGIN;

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

-- ── Section 7 · Verification (fails migration if any assertion trips) ───────────

DO $$
DECLARE
  v_master_type TEXT;
  v_fk_count INTEGER;
  v_orphans INTEGER;
BEGIN
  SELECT data_type INTO v_master_type
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='account_master_codes' AND column_name='code';

  SELECT COUNT(*) INTO v_fk_count
  FROM information_schema.table_constraints
  WHERE table_schema='public' AND table_name='chart_of_accounts'
    AND constraint_type='FOREIGN KEY'
    AND constraint_name = 'chart_of_accounts_master_code_fkey';

  SELECT COUNT(*) INTO v_orphans
  FROM public.chart_of_accounts coa
  WHERE coa.agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND NOT EXISTS (
      SELECT 1 FROM public.account_master_codes amc
      WHERE amc.agency_id = coa.agency_id AND amc.code = coa.account_code
    );

  IF v_master_type <> 'text' THEN
    RAISE EXCEPTION 'Ch11 verify: expected account_master_codes.code to be TEXT, got %', v_master_type;
  END IF;
  IF v_fk_count <> 1 THEN
    RAISE EXCEPTION 'Ch11 verify: FK constraint not present (count=%)', v_fk_count;
  END IF;
  IF v_orphans <> 0 THEN
    RAISE EXCEPTION 'Ch11 verify: % chart_of_accounts rows with no master code match', v_orphans;
  END IF;

  RAISE NOTICE 'Ch11 done: master.code is TEXT, FK enforced, 0 orphans';
END;
$$;

COMMIT;
