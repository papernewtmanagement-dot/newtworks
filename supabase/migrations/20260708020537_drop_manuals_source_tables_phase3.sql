-- ============================================================================
-- Manuals consolidation Phase 3: drop source tables + sync triggers + trigger fns.
-- All readers now point at public.manuals with a manual_type filter.
-- Row counts verified matched immediately before this migration (see session log).
-- Dropping tables cascades their triggers; trigger functions dropped explicitly.
-- ============================================================================

DROP TABLE IF EXISTS public.handbook    CASCADE;
DROP TABLE IF EXISTS public.processes   CASCADE;
DROP TABLE IF EXISTS public.admin_pages CASCADE;

DROP FUNCTION IF EXISTS public.sync_handbook_to_manuals();
DROP FUNCTION IF EXISTS public.sync_processes_to_manuals();
DROP FUNCTION IF EXISTS public.sync_admin_pages_to_manuals();

COMMENT ON TABLE public.manuals IS 'Sole authority for handbook, processes, admin, and future manuals content. Source tables (handbook, processes, admin_pages) dropped 2026-07-08 (Phase 3 consolidation).';
