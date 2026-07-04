-- ============================================================
-- Tech Book dismantle (2026-07-04)
-- Peter's directive: dismantle Tech Support tree entirely.
-- Six pages archived, six moved into Playbook, one to Handbook,
-- Tech Support removed from tree_root check constraint.
-- ============================================================

-- 1) MOVES INTO PLAYBOOK (tree_root -> 'Checklists')

-- Fax -> under 01 Reception
UPDATE public.playbook
SET parent_page_id = '1746010123',
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Moved 2026-07-04 from Tech Support -> 01 Reception.',
    updated_at = NOW()
WHERE id = '149bf69f-95c2-4ae8-a224-99600d76a3a9';

-- Policyholder List Creation -> under 03 FIT Conversations
UPDATE public.playbook
SET parent_page_id = '2124251137',
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Moved 2026-07-04 from Tech Support -> 03 FIT Conversations.',
    updated_at = NOW()
WHERE id = '3fff3b19-f1df-4fbd-a12d-3d5e15fb2c36';

-- SPAM Listings -> under 03 FIT Conversations
UPDATE public.playbook
SET parent_page_id = '2124251137',
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Moved 2026-07-04 from Tech Support -> 03 FIT Conversations.',
    updated_at = NOW()
WHERE id = '0533d528-d32d-49d9-b7a7-4b70bb9f2436';

-- Desk Checklist (was child of Systems Setup) -> under Training
UPDATE public.playbook
SET parent_page_id = '2716532737',
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Moved 2026-07-04 from Tech Support/Systems Setup -> Training.',
    updated_at = NOW()
WHERE id = '128631d0-d5cd-4328-8d04-87b855e550c0';

-- Office - Systems Setup (was child of Systems Setup) -> under Training
UPDATE public.playbook
SET parent_page_id = '2716532737',
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Moved 2026-07-04 from Tech Support/Systems Setup -> Training.',
    updated_at = NOW()
WHERE id = 'a11fa80c-d8bb-4794-8e21-6046bf61c6c7';

-- Grandchildren of Systems Setup keep their parent (Office - Systems Setup, confluence 1283129345)
-- but need tree_root flipped to 'Checklists'
UPDATE public.playbook
SET tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Tree root re-parented 2026-07-04 (parent Office - Systems Setup moved to Training).',
    updated_at = NOW()
WHERE id IN (
  '5920aaf9-bba9-4f9a-8cb9-12a74306cff2',  -- Team by the Minute
  '912618be-5680-4296-808e-8d8baa7b12e7'   -- Voicemail & Automated Attendant
);

-- 2) MOVE TEAM LIST TO HANDBOOK
INSERT INTO public.handbook (
  agency_id, title, content, source_url, confluence_page_id,
  parent_page_id, content_format, version, is_active, fetched_at, notes, created_at, updated_at
)
SELECT
  agency_id, title, content, source_url, confluence_page_id,
  NULL AS parent_page_id, content_format, version, is_active, fetched_at,
  COALESCE(notes || E'\n', '') || 'Moved 2026-07-04 from Playbook Tech Support -> Handbook.' AS notes,
  NOW(), NOW()
FROM public.playbook
WHERE id = '61dc41bb-cc0b-4c99-838a-adaa08635eb9';

UPDATE public.playbook
SET is_active = false,
    archived_at = NOW(),
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Archived 2026-07-04: moved to Handbook.',
    updated_at = NOW()
WHERE id = '61dc41bb-cc0b-4c99-838a-adaa08635eb9';

-- 3) ARCHIVES (soft-delete + set tree_root='Checklists' so constraint tighten below passes)
UPDATE public.playbook
SET is_active = false,
    archived_at = NOW(),
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Archived 2026-07-04 during Tech Book dismantle (was tree_root=Tech Support).',
    updated_at = NOW()
WHERE id IN (
  'bd6eba70-2017-47c9-8bb4-6a5bf5d217d7', -- Blackberry Work App
  '748b3ab0-bfdd-4612-b8e3-65ebc3071d79', -- Cloud Drive Inactive
  '1d24fa56-3f75-452b-9bcc-13eaeae36e2f', -- Ctrl-D Reports
  '4022ab6d-a2c6-47f4-bd5b-8169fada4734', -- GNC Troubleshooting - Tech Support
  '06e99d0d-6b58-413e-ae3c-1015eae9f305', -- Social Media Access
  'e4a12602-5d0e-4e8e-8b3b-ca553431d05c'  -- Systems Setup (wrapper)
);

-- 4) DSS Tech Support -> Training (default landing; Peter to reparent as needed)
UPDATE public.playbook
SET parent_page_id = '2716532737',
    tree_root = 'Checklists',
    notes = COALESCE(notes || E'\n', '') || 'Moved 2026-07-04 from Tech Support -> Training (default landing; reparent as needed).',
    updated_at = NOW()
WHERE id = 'be8934af-32c7-4f43-87f3-b40403efb033';

-- 5) VERIFY: zero Tech Support rows should remain
DO $$
DECLARE
  remaining INT;
BEGIN
  SELECT COUNT(*) INTO remaining
  FROM public.playbook
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND tree_root = 'Tech Support';
  IF remaining > 0 THEN
    RAISE EXCEPTION 'Tech Support rows still present after dismantle: %', remaining;
  END IF;
END $$;

-- 6) TIGHTEN CONSTRAINT -- drop 'Tech Support' from allowed values
ALTER TABLE public.playbook
  DROP CONSTRAINT IF EXISTS playbook_tree_root_check;

ALTER TABLE public.playbook
  ADD CONSTRAINT playbook_tree_root_check
  CHECK (tree_root = ANY (ARRAY['Checklists'::text, 'Product Knowledge'::text]));
