CREATE TABLE IF NOT EXISTS public.admin_pages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  title text NOT NULL,
  content text NOT NULL,
  content_format text NOT NULL DEFAULT 'markdown'
    CHECK (content_format = ANY (ARRAY['markdown'::text, 'plaintext'::text, 'html'::text, 'confluence_storage'::text])),
  source_url text,
  confluence_page_id text,
  parent_page_id text,
  version integer NOT NULL DEFAULT 1,
  is_active boolean NOT NULL DEFAULT true,
  archived_at timestamptz,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_pages_agency_active_idx
  ON public.admin_pages (agency_id, is_active, fetched_at DESC);

CREATE INDEX IF NOT EXISTS admin_pages_confluence_page_id_idx
  ON public.admin_pages (agency_id, confluence_page_id);

CREATE UNIQUE INDEX IF NOT EXISTS admin_pages_one_active_per_title
  ON public.admin_pages (agency_id, title) WHERE (is_active = true);

COMMENT ON TABLE public.admin_pages IS 'Internal admin/back-office content ingested from Confluence ~Admin tree. Mirrors handbook structure (no tree_root). Created 2026-06-21 to store ~Admin pages excluded from playbook by tree_root check constraint.';
