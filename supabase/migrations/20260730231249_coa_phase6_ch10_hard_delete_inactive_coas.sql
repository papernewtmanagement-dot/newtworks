-- CoA Phase 6 · Chunk 10 · Migration B
-- Hard-delete the 186 inactive chart_of_accounts rows for agency 126794dd-25ff-47d2-a436-724499733365.

-- ── Section 1 · Snapshot audit trail before nulling FKs ────────────────────────

ALTER TABLE public.journal_lines
  ADD COLUMN IF NOT EXISTS original_account_code TEXT,
  ADD COLUMN IF NOT EXISTS original_account_name TEXT;

UPDATE public.journal_lines jl
SET original_account_code = coa.account_code,
    original_account_name = coa.account_name
FROM public.chart_of_accounts coa
WHERE jl.original_account_id = coa.id
  AND jl.original_account_id IS NOT NULL
  AND (jl.original_account_code IS NULL OR jl.original_account_name IS NULL);

ALTER TABLE public.account_reclassifications
  ADD COLUMN IF NOT EXISTS from_account_code TEXT,
  ADD COLUMN IF NOT EXISTS from_account_name TEXT,
  ADD COLUMN IF NOT EXISTS from_business_entity_id UUID;

UPDATE public.account_reclassifications ar
SET from_account_code = coa.account_code,
    from_account_name = coa.account_name,
    from_business_entity_id = coa.business_entity_id
FROM public.chart_of_accounts coa
WHERE ar.from_account_id = coa.id
  AND ar.from_account_id IS NOT NULL
  AND (ar.from_account_code IS NULL OR ar.from_account_name IS NULL);

-- ── Section 2 · Drop NOT NULL on account_reclassifications.from_account_id ──────

ALTER TABLE public.account_reclassifications
  ALTER COLUMN from_account_id DROP NOT NULL;

-- ── Section 3 · Repoint the live bank_account_map row (last4=2353) ──────────────

UPDATE public.bank_account_map
SET bank_account_id = (
      SELECT id FROM public.chart_of_accounts
      WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND account_code = '1010'
        AND is_active = true
    ),
    notes = COALESCE(notes, '') || ' [Ch10: repointed from inactive COA-024 to active 1010]',
    updated_at = NOW()
WHERE id = '999acd5c-78cd-4c00-af4a-9e0c2f47c128';

-- ── Section 4 · Null the retired Spark credit_accounts.chart_account_id ─────────

UPDATE public.credit_accounts
SET chart_account_id = NULL,
    updated_at = NOW()
WHERE id = '7d14d300-d19f-4778-b53b-104664308291';

-- ── Section 5 · Null all inactive-to-inactive parent self-references ────────────

UPDATE public.chart_of_accounts
SET parent_account_id = NULL
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = false
  AND parent_account_id IS NOT NULL;

-- ── Section 6 · Null the FK columns after audit trail is preserved ──────────────

UPDATE public.journal_lines
SET original_account_id = NULL
WHERE original_account_id IN (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active = false
);

UPDATE public.account_reclassifications
SET from_account_id = NULL
WHERE from_account_id IN (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active = false
);

-- ── Section 7 · Hard-DELETE the 186 inactive chart_of_accounts rows ─────────────

DELETE FROM public.chart_of_accounts
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = false;

-- ── Section 8 · Post-delete verification ─────────────────────────────────────────

DO $$
DECLARE
  v_active_count INTEGER;
  v_inactive_count INTEGER;
  v_orphan_original INTEGER;
  v_orphan_from INTEGER;
  v_orphan_bam INTEGER;
  v_snapshot_jl INTEGER;
  v_snapshot_ar INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_active_count FROM public.chart_of_accounts
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active = true;
  SELECT COUNT(*) INTO v_inactive_count FROM public.chart_of_accounts
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active = false;
  SELECT COUNT(*) INTO v_orphan_original FROM public.journal_lines jl
    WHERE jl.original_account_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts c WHERE c.id = jl.original_account_id);
  SELECT COUNT(*) INTO v_orphan_from FROM public.account_reclassifications ar
    WHERE ar.from_account_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts c WHERE c.id = ar.from_account_id);
  SELECT COUNT(*) INTO v_orphan_bam FROM public.bank_account_map bam
    WHERE bam.bank_account_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts c WHERE c.id = bam.bank_account_id);
  SELECT COUNT(*) INTO v_snapshot_jl FROM public.journal_lines WHERE original_account_code IS NOT NULL;
  SELECT COUNT(*) INTO v_snapshot_ar FROM public.account_reclassifications WHERE from_account_code IS NOT NULL;

  IF v_active_count <> 162 THEN RAISE EXCEPTION 'Ch10 verify: expected 162 active COAs, got %', v_active_count; END IF;
  IF v_inactive_count <> 0 THEN RAISE EXCEPTION 'Ch10 verify: expected 0 inactive COAs, got %', v_inactive_count; END IF;
  IF v_orphan_original <> 0 THEN RAISE EXCEPTION 'Ch10 verify: % dangling journal_lines.original_account_id refs', v_orphan_original; END IF;
  IF v_orphan_from <> 0 THEN RAISE EXCEPTION 'Ch10 verify: % dangling account_reclassifications.from_account_id refs', v_orphan_from; END IF;
  IF v_orphan_bam <> 0 THEN RAISE EXCEPTION 'Ch10 verify: % dangling bank_account_map.bank_account_id refs', v_orphan_bam; END IF;
  IF v_snapshot_jl < 1000 THEN RAISE EXCEPTION 'Ch10 verify: expected >=1000 journal_lines snapshots, got %', v_snapshot_jl; END IF;
  IF v_snapshot_ar < 40 THEN RAISE EXCEPTION 'Ch10 verify: expected >=40 account_reclassifications snapshots, got %', v_snapshot_ar; END IF;

  RAISE NOTICE 'Ch10 done: 162 active COAs, 0 inactive, audit trail preserved (% jl snapshots, % ar snapshots)',
    v_snapshot_jl, v_snapshot_ar;
END;
$$;
