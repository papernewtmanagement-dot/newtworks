-- CoA Phase 6 · Chunk 10 · Migration B
-- Hard-delete the 186 inactive chart_of_accounts rows for agency 126794dd-25ff-47d2-a436-724499733365.
--
-- Pre-flight state (2026-07-30):
--   162 active COAs, all with parent_account_id = NULL (Ch9 output)
--   186 inactive COAs (this migration deletes all of them)
--
-- Blocking references discovered:
--   journal_lines.original_account_id ....... 1110 rows point at inactive COAs (Phase 4 reclass audit trail)
--   account_reclassifications.from_account_id .. 47 rows (Phase 4 reclass audit; NOT NULL constrained)
--   chart_of_accounts.parent_account_id ..... 162 inactive-parent-of-inactive self-refs
--   credit_accounts.chart_account_id ........ 1 row (Spark - Discretionary, is_active=false legacy)
--   bank_account_map.bank_account_id ........ 1 row (last4=2353, LIVE; repoint to active 1010)
--   journal_lines.account_id ................ 0 (clean, Phase 4 moved all postings to destinations)
--   bank_transactions.bank_account_id ....... 0 (clean)
--   account_reclassifications.to_account_id . 0 (destinations are all active)
--
-- 4-row drift note vs handoff plan: Phase 5b op-rule quoted 182 inactive orphans.
-- Current state is 186 (Phase 4 completion figure). The 4-row gap is that Phase 5b counted
-- under a stricter filter that excluded rows still serving as headers of active accounts at
-- that moment. Ch9 nulled all active parents, so all 186 are now unblocked. No functional
-- discrepancy; just a definition drift in the interim op-rule snapshot.
--
-- Strategy:
--   (a) Preserve the Phase 4 reclassification audit trail as TEXT snapshot columns before
--       nulling the FK columns that point at inactive COAs. The whole point of the
--       original_account_id / from_account_id fields was to preserve the audit — dropping
--       them without snapshots would destroy the "why did this move here" trail.
--   (b) Drop NOT NULL on account_reclassifications.from_account_id (safe: the audit is now
--       preserved in the richer from_account_code + from_account_name + from_business_entity_id
--       snapshot columns).
--   (c) Repoint the live bank_account_map row (last4=2353) to the current active
--       COA 1010 "PSS — Operating Checking (2353)".
--   (d) Null the chart_account_id on the retired Spark credit_accounts row (row itself
--       stays with its -$3,425.14 historical balance; only the stale FK is cleared).
--   (e) Null all inactive-to-inactive parent_account_id self-references.
--   (f) DELETE all 186 inactive chart_of_accounts rows in a single statement.

BEGIN;

-- ── Section 1 · Snapshot audit trail before nulling FKs ────────────────────────

-- journal_lines: preserve original account code + name as text snapshots.
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

-- account_reclassifications: preserve source account code + name + entity as text snapshots.
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
-- Audit trail is now preserved in the richer text snapshot columns above, so the
-- UUID FK can be nulled without information loss.

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

-- ── Section 8 · Post-delete verification (fails migration if any assertion trips) ─

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
  SELECT COUNT(*) INTO v_active_count
  FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active = true;

  SELECT COUNT(*) INTO v_inactive_count
  FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active = false;

  SELECT COUNT(*) INTO v_orphan_original
  FROM public.journal_lines jl
  WHERE jl.original_account_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts c WHERE c.id = jl.original_account_id);

  SELECT COUNT(*) INTO v_orphan_from
  FROM public.account_reclassifications ar
  WHERE ar.from_account_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts c WHERE c.id = ar.from_account_id);

  SELECT COUNT(*) INTO v_orphan_bam
  FROM public.bank_account_map bam
  WHERE bam.bank_account_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts c WHERE c.id = bam.bank_account_id);

  SELECT COUNT(*) INTO v_snapshot_jl
  FROM public.journal_lines
  WHERE original_account_code IS NOT NULL;

  SELECT COUNT(*) INTO v_snapshot_ar
  FROM public.account_reclassifications
  WHERE from_account_code IS NOT NULL;

  IF v_active_count <> 162 THEN
    RAISE EXCEPTION 'Ch10 verify: expected 162 active COAs, got %', v_active_count;
  END IF;
  IF v_inactive_count <> 0 THEN
    RAISE EXCEPTION 'Ch10 verify: expected 0 inactive COAs, got %', v_inactive_count;
  END IF;
  IF v_orphan_original <> 0 THEN
    RAISE EXCEPTION 'Ch10 verify: % dangling journal_lines.original_account_id refs', v_orphan_original;
  END IF;
  IF v_orphan_from <> 0 THEN
    RAISE EXCEPTION 'Ch10 verify: % dangling account_reclassifications.from_account_id refs', v_orphan_from;
  END IF;
  IF v_orphan_bam <> 0 THEN
    RAISE EXCEPTION 'Ch10 verify: % dangling bank_account_map.bank_account_id refs', v_orphan_bam;
  END IF;
  IF v_snapshot_jl < 1000 THEN
    RAISE EXCEPTION 'Ch10 verify: expected ≥1000 journal_lines snapshots, got %', v_snapshot_jl;
  END IF;
  IF v_snapshot_ar < 40 THEN
    RAISE EXCEPTION 'Ch10 verify: expected ≥40 account_reclassifications snapshots, got %', v_snapshot_ar;
  END IF;

  RAISE NOTICE 'Ch10 done: 162 active COAs, 0 inactive, audit trail preserved (% jl snapshots, % ar snapshots)',
    v_snapshot_jl, v_snapshot_ar;
END;
$$;

COMMIT;
