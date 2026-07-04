-- ============================================================
-- Tech Book: hard-delete archives + reparent DSS to Reception
-- Correcting 2026-07-04 dismantle: Peter said "permanently delete
-- that section" -- soft-delete was insufficient. DSS Tech Support
-- belongs under Reception, not Training.
-- ============================================================

-- 1) HARD-DELETE the 6 archived Tech Book rows + archived Team List
DELETE FROM public.playbook
WHERE id IN (
  'bd6eba70-2017-47c9-8bb4-6a5bf5d217d7', -- Blackberry Work App
  '748b3ab0-bfdd-4612-b8e3-65ebc3071d79', -- Cloud Drive Inactive
  '1d24fa56-3f75-452b-9bcc-13eaeae36e2f', -- Ctrl-D Reports
  '4022ab6d-a2c6-47f4-bd5b-8169fada4734', -- GNC Troubleshooting - Tech Support
  '06e99d0d-6b58-413e-ae3c-1015eae9f305', -- Social Media Access
  'e4a12602-5d0e-4e8e-8b3b-ca553431d05c', -- Systems Setup (wrapper)
  '61dc41bb-cc0b-4c99-838a-adaa08635eb9'  -- Team List (moved to handbook)
);

-- 2) DSS Tech Support -> under 01 Reception (parent 1746010123)
UPDATE public.playbook
SET parent_page_id = '1746010123',
    notes = COALESCE(notes || E'\n', '') || 'Reparented 2026-07-04 from Training -> 01 Reception per Peter.',
    updated_at = NOW()
WHERE id = 'be8934af-32c7-4f43-87f3-b40403efb033';
