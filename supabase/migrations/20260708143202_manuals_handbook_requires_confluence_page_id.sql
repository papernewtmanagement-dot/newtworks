-- Prevent the "clicking Team Growth navigates to Glossary" class of bug.
-- Manual.jsx uses confluence_page_id as the routing key for handbook pages,
-- so a NULL there short-circuits URL update and falls through to the
-- default-root effect, sending the user to a different page.
-- Only handbook is constrained — processes/admin_pages/excerpt keep flexibility.

ALTER TABLE public.manuals
  DROP CONSTRAINT IF EXISTS manuals_handbook_requires_confluence_page_id;

ALTER TABLE public.manuals
  ADD CONSTRAINT manuals_handbook_requires_confluence_page_id
  CHECK (manual_type <> 'handbook' OR confluence_page_id IS NOT NULL);
