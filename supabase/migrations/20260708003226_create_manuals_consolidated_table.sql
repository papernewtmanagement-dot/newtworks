-- ============================================================================
-- Manuals consolidation Phase 1: create unified table + dual-write triggers.
-- Frontend/edge functions still read/write source tables (handbook, processes,
-- admin_pages). Triggers mirror all writes into public.manuals. Phase 2 swaps
-- readers to manuals; Phase 3 drops the source tables.
-- ============================================================================

-- 1. The unified table ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.manuals (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    agency_id          uuid NOT NULL,
    manual_type        text NOT NULL,
    tree_root          text NULL,       -- used by manual_type='processes' (Checklists, Product Knowledge); NULL for others
    title              text NOT NULL,
    content            text NOT NULL,
    content_format     text NOT NULL DEFAULT 'markdown',
    source_url         text NULL,
    confluence_page_id text NULL,
    parent_page_id     text NULL,
    version            integer NOT NULL DEFAULT 1,
    is_active          boolean NOT NULL DEFAULT true,
    archived_at        timestamptz NULL,
    fetched_at         timestamptz NOT NULL DEFAULT now(),
    notes              text NULL,
    sort_order         integer NULL,
    icon               text NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT manuals_manual_type_check CHECK (
        manual_type IN ('handbook','processes','admin','roleplaying','financial_literacy','investments')
    )
);

CREATE INDEX IF NOT EXISTS idx_manuals_agency_type_active ON public.manuals (agency_id, manual_type, is_active);
CREATE INDEX IF NOT EXISTS idx_manuals_parent              ON public.manuals (parent_page_id);
CREATE INDEX IF NOT EXISTS idx_manuals_confluence          ON public.manuals (confluence_page_id);

-- 2. RLS matches Manuals Rulebook wide-open pattern for now ------------------
ALTER TABLE public.manuals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_all_manuals          ON public.manuals;
DROP POLICY IF EXISTS authenticated_all_manuals ON public.manuals;

CREATE POLICY anon_all_manuals          ON public.manuals FOR ALL TO anon          USING (true) WITH CHECK (true);
CREATE POLICY authenticated_all_manuals ON public.manuals FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 3. Dual-write trigger functions --------------------------------------------
-- One-way sync: source -> manuals. Preserves source PK as manuals PK, so any
-- deep-links using UUIDs continue to resolve after the eventual source drop.

CREATE OR REPLACE FUNCTION public.sync_handbook_to_manuals()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.manuals WHERE id = OLD.id AND manual_type = 'handbook';
    RETURN OLD;
  END IF;
  INSERT INTO public.manuals (id, agency_id, manual_type, tree_root, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at)
  VALUES (NEW.id, NEW.agency_id, 'handbook', NULL, NEW.title, NEW.content, NEW.content_format, NEW.source_url, NEW.confluence_page_id, NEW.parent_page_id, NEW.version, NEW.is_active, NEW.archived_at, NEW.fetched_at, NEW.notes, NEW.sort_order, NEW.icon, NEW.created_at, NEW.updated_at)
  ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title, content = EXCLUDED.content, content_format = EXCLUDED.content_format,
    source_url = EXCLUDED.source_url, confluence_page_id = EXCLUDED.confluence_page_id,
    parent_page_id = EXCLUDED.parent_page_id, version = EXCLUDED.version,
    is_active = EXCLUDED.is_active, archived_at = EXCLUDED.archived_at,
    fetched_at = EXCLUDED.fetched_at, notes = EXCLUDED.notes,
    sort_order = EXCLUDED.sort_order, icon = EXCLUDED.icon,
    updated_at = EXCLUDED.updated_at;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_processes_to_manuals()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.manuals WHERE id = OLD.id AND manual_type = 'processes';
    RETURN OLD;
  END IF;
  INSERT INTO public.manuals (id, agency_id, manual_type, tree_root, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at)
  VALUES (NEW.id, NEW.agency_id, 'processes', NEW.tree_root, NEW.title, NEW.content, NEW.content_format, NEW.source_url, NEW.confluence_page_id, NEW.parent_page_id, NEW.version, NEW.is_active, NEW.archived_at, NEW.fetched_at, NEW.notes, NEW.sort_order, NEW.icon, NEW.created_at, NEW.updated_at)
  ON CONFLICT (id) DO UPDATE SET
    tree_root = EXCLUDED.tree_root,
    title = EXCLUDED.title, content = EXCLUDED.content, content_format = EXCLUDED.content_format,
    source_url = EXCLUDED.source_url, confluence_page_id = EXCLUDED.confluence_page_id,
    parent_page_id = EXCLUDED.parent_page_id, version = EXCLUDED.version,
    is_active = EXCLUDED.is_active, archived_at = EXCLUDED.archived_at,
    fetched_at = EXCLUDED.fetched_at, notes = EXCLUDED.notes,
    sort_order = EXCLUDED.sort_order, icon = EXCLUDED.icon,
    updated_at = EXCLUDED.updated_at;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_admin_pages_to_manuals()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.manuals WHERE id = OLD.id AND manual_type = 'admin';
    RETURN OLD;
  END IF;
  INSERT INTO public.manuals (id, agency_id, manual_type, tree_root, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at)
  VALUES (NEW.id, NEW.agency_id, 'admin', NULL, NEW.title, NEW.content, NEW.content_format, NEW.source_url, NEW.confluence_page_id, NEW.parent_page_id, NEW.version, NEW.is_active, NEW.archived_at, NEW.fetched_at, NEW.notes, NEW.sort_order, NEW.icon, NEW.created_at, NEW.updated_at)
  ON CONFLICT (id) DO UPDATE SET
    title = EXCLUDED.title, content = EXCLUDED.content, content_format = EXCLUDED.content_format,
    source_url = EXCLUDED.source_url, confluence_page_id = EXCLUDED.confluence_page_id,
    parent_page_id = EXCLUDED.parent_page_id, version = EXCLUDED.version,
    is_active = EXCLUDED.is_active, archived_at = EXCLUDED.archived_at,
    fetched_at = EXCLUDED.fetched_at, notes = EXCLUDED.notes,
    sort_order = EXCLUDED.sort_order, icon = EXCLUDED.icon,
    updated_at = EXCLUDED.updated_at;
  RETURN NEW;
END;
$$;

-- 4. Attach triggers ---------------------------------------------------------
DROP TRIGGER IF EXISTS trg_sync_handbook_to_manuals    ON public.handbook;
DROP TRIGGER IF EXISTS trg_sync_processes_to_manuals   ON public.processes;
DROP TRIGGER IF EXISTS trg_sync_admin_pages_to_manuals ON public.admin_pages;

CREATE TRIGGER trg_sync_handbook_to_manuals
  AFTER INSERT OR UPDATE OR DELETE ON public.handbook
  FOR EACH ROW EXECUTE FUNCTION public.sync_handbook_to_manuals();

CREATE TRIGGER trg_sync_processes_to_manuals
  AFTER INSERT OR UPDATE OR DELETE ON public.processes
  FOR EACH ROW EXECUTE FUNCTION public.sync_processes_to_manuals();

CREATE TRIGGER trg_sync_admin_pages_to_manuals
  AFTER INSERT OR UPDATE OR DELETE ON public.admin_pages
  FOR EACH ROW EXECUTE FUNCTION public.sync_admin_pages_to_manuals();

-- 5. Backfill existing rows --------------------------------------------------
INSERT INTO public.manuals (id, agency_id, manual_type, tree_root, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at)
SELECT id, agency_id, 'handbook', NULL, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at
FROM public.handbook
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.manuals (id, agency_id, manual_type, tree_root, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at)
SELECT id, agency_id, 'processes', tree_root, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at
FROM public.processes
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.manuals (id, agency_id, manual_type, tree_root, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at)
SELECT id, agency_id, 'admin', NULL, title, content, content_format, source_url, confluence_page_id, parent_page_id, version, is_active, archived_at, fetched_at, notes, sort_order, icon, created_at, updated_at
FROM public.admin_pages
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE  public.manuals             IS 'Unified manuals table (Phase 1 consolidation). Sources: handbook, processes, admin_pages. Dual-write triggers mirror source writes here until frontend/edge functions swap over.';
COMMENT ON COLUMN public.manuals.manual_type IS 'handbook | processes | admin | roleplaying | financial_literacy | investments';
COMMENT ON COLUMN public.manuals.tree_root   IS 'Optional secondary partition. Currently only manual_type=processes uses it (Checklists, Product Knowledge).';
