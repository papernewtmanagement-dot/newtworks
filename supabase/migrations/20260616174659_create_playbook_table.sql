CREATE TABLE IF NOT EXISTS public.playbook (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  title text NOT NULL,
  content text NOT NULL,
  content_format text NOT NULL DEFAULT 'markdown' CHECK (content_format IN ('markdown', 'plaintext', 'html', 'confluence_storage')),
  source_url text,
  confluence_page_id text,
  parent_page_id text,
  tree_root text NOT NULL CHECK (tree_root IN ('Checklists', 'Product Knowledge', 'Tech Support')),
  version integer NOT NULL DEFAULT 1,
  is_active boolean NOT NULL DEFAULT true,
  archived_at timestamptz,
  fetched_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS playbook_one_active_per_title ON public.playbook (agency_id, title) WHERE (is_active = true);
CREATE INDEX IF NOT EXISTS playbook_agency_active_idx ON public.playbook (agency_id, is_active, fetched_at DESC);
CREATE INDEX IF NOT EXISTS playbook_confluence_page_id_idx ON public.playbook (agency_id, confluence_page_id);
CREATE INDEX IF NOT EXISTS playbook_tree_root_idx ON public.playbook (agency_id, tree_root);

ALTER TABLE public.playbook ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_all_playbook ON public.playbook;
DROP POLICY IF EXISTS authenticated_all_playbook ON public.playbook;
CREATE POLICY anon_all_playbook ON public.playbook FOR ALL TO anon USING (true) WITH CHECK (true);
CREATE POLICY authenticated_all_playbook ON public.playbook FOR ALL TO authenticated USING (true) WITH CHECK (true);
