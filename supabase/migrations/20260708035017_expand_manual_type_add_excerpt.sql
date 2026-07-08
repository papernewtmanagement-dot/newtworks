-- Migration: expand manual_type CHECK constraint to accept 'excerpt'
--
-- Excerpt rows are named-fragment sources referenced by
-- [Embedded excerpt from: X] markers on other pages. They live in a
-- dedicated manual_type='excerpt' scope so they can be:
--   1. Loaded independently of the active manual_type by consumers
--      (see Manual.jsx: separate query for excerpts alongside the
--      active-manual query)
--   2. Hidden from the tree UI (Manual.jsx never renders 'excerpt' rows
--      in the tree navigation since the tree is filtered by manual_type)
--
-- Applied via Supabase MCP on 2026-07-08 alongside insertion of 10
-- excerpt rows recovered from Confluence excerpt-macro definitions on
-- source pages `03 FIT Conversations` (page id 2124251137) and
-- `Checklists` (page id 1726480570).

ALTER TABLE public.manuals DROP CONSTRAINT IF EXISTS manuals_manual_type_check;
ALTER TABLE public.manuals ADD CONSTRAINT manuals_manual_type_check
  CHECK (manual_type = ANY (ARRAY[
    'handbook'::text,
    'processes'::text,
    'admin'::text,
    'roleplaying'::text,
    'financial_literacy'::text,
    'investments'::text,
    'excerpt'::text
  ]));
