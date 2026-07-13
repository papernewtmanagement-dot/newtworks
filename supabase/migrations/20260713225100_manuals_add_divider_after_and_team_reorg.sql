-- Migration: manuals_add_divider_after_and_team_reorg
-- Applied 2026-07-13.
-- Part 1: schema — add divider_after column for nav-tree visual separator.
-- Part 2: rename Hiring → "Team", move to sort_order 15 (between Tax Process @10 and Bookkeeping @20),
--         and flag the section divider AFTER it.
-- Part 3: move Termination under Team (parent_page_id = Team's confluence_page_id '2716663809'),
--         sort_order 110 (after Onboarding Schedule @100).

ALTER TABLE public.manuals
  ADD COLUMN IF NOT EXISTS divider_after boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.manuals.divider_after IS
  'When true, the Manual.jsx sidebar tree renders a horizontal <hr> after this top-level node (and after its entire visible subtree). Used to visually mark section boundaries — e.g. divide organized reference from still-to-organize content in the admin manual.';

UPDATE public.manuals
SET title = 'Team',
    sort_order = 15,
    divider_after = true,
    updated_at = NOW()
WHERE id = 'c7b8c163-f3fd-4c24-bb18-c4f8f17dcd11'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'admin';

UPDATE public.manuals
SET parent_page_id = '2716663809',
    sort_order = 110,
    updated_at = NOW()
WHERE id = '6668c6e0-662f-4826-81bb-6caad57d9c55'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'admin';
