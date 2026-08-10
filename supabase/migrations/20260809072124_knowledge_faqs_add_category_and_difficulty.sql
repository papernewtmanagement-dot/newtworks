-- Lookup table for FAQ categories (line of business / topic area)
CREATE TABLE IF NOT EXISTS public.knowledge_faq_categories (
  id uuid NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  agency_id uuid NOT NULL,
  slug text NOT NULL,
  label text NOT NULL,
  line_group text NOT NULL,
  is_state_farm boolean NOT NULL DEFAULT false,
  generic_slug text,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT knowledge_faq_categories_line_group_chk
    CHECK (line_group IN ('foundational','personal_insurance','financial_services','commercial'))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_knowledge_faq_categories_agency_slug
  ON public.knowledge_faq_categories (agency_id, slug);

ALTER TABLE public.knowledge_faq_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_read_knowledge_faq_categories ON public.knowledge_faq_categories;
CREATE POLICY team_read_knowledge_faq_categories ON public.knowledge_faq_categories
  FOR SELECT USING (
    agency_id IN (SELECT u.agency_id FROM users u WHERE u.auth_user_id = auth.uid())
  );

DROP POLICY IF EXISTS admin_insert_knowledge_faq_categories ON public.knowledge_faq_categories;
CREATE POLICY admin_insert_knowledge_faq_categories ON public.knowledge_faq_categories
  FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM users u WHERE u.auth_user_id = auth.uid()
      AND u.role = ANY (ARRAY['owner','manager']) AND u.agency_id = knowledge_faq_categories.agency_id AND u.is_active = true)
  );

DROP POLICY IF EXISTS admin_update_knowledge_faq_categories ON public.knowledge_faq_categories;
CREATE POLICY admin_update_knowledge_faq_categories ON public.knowledge_faq_categories
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM users u WHERE u.auth_user_id = auth.uid()
      AND u.role = ANY (ARRAY['owner','manager']) AND u.agency_id = knowledge_faq_categories.agency_id AND u.is_active = true)
  ) WITH CHECK (
    EXISTS (SELECT 1 FROM users u WHERE u.auth_user_id = auth.uid()
      AND u.role = ANY (ARRAY['owner','manager']) AND u.agency_id = knowledge_faq_categories.agency_id AND u.is_active = true)
  );

DROP POLICY IF EXISTS admin_delete_knowledge_faq_categories ON public.knowledge_faq_categories;
CREATE POLICY admin_delete_knowledge_faq_categories ON public.knowledge_faq_categories
  FOR DELETE USING (
    EXISTS (SELECT 1 FROM users u WHERE u.auth_user_id = auth.uid()
      AND u.role = ANY (ARRAY['owner','manager']) AND u.agency_id = knowledge_faq_categories.agency_id AND u.is_active = true)
  );

-- New columns on knowledge_faqs
ALTER TABLE public.knowledge_faqs ADD COLUMN IF NOT EXISTS category text;
ALTER TABLE public.knowledge_faqs ADD COLUMN IF NOT EXISTS difficulty text;

ALTER TABLE public.knowledge_faqs DROP CONSTRAINT IF EXISTS knowledge_faqs_difficulty_chk;
ALTER TABLE public.knowledge_faqs ADD CONSTRAINT knowledge_faqs_difficulty_chk
  CHECK (difficulty IS NULL OR difficulty IN ('basic','intermediate','advanced'));

CREATE INDEX IF NOT EXISTS idx_knowledge_faqs_category ON public.knowledge_faqs (agency_id, category);
CREATE INDEX IF NOT EXISTS idx_knowledge_faqs_difficulty ON public.knowledge_faqs (agency_id, difficulty);

COMMENT ON COLUMN public.knowledge_faqs.category IS 'Line-of-business / topic slug. Matches knowledge_faq_categories.slug.';
COMMENT ON COLUMN public.knowledge_faqs.difficulty IS 'basic | intermediate | advanced. Drives quiz tiering and teaching order.';
