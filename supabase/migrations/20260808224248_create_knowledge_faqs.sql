-- create_knowledge_faqs
-- Wave 1 of 5, trivia project: shared knowledge bank table + safety backup table.

CREATE TABLE IF NOT EXISTS public.knowledge_faqs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  topic_key         text NOT NULL,
  question          text NOT NULL,
  answer            text NOT NULL,
  faq_type          text NOT NULL CHECK (faq_type IN ('discount','policy','process','system','general')),
  product_line      text NULL,
  source_manual_id  uuid NULL REFERENCES public.manuals(id),
  source_anchor     text NULL,
  sort_order        integer NOT NULL DEFAULT 0,
  is_active         boolean NOT NULL DEFAULT true,
  status            text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','retired')),
  approved_at       timestamptz NULL,
  approved_by       uuid NULL REFERENCES public.team(id),
  notes             text NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_knowledge_faqs_agency_topic_question
  ON public.knowledge_faqs (agency_id, topic_key, question);

CREATE INDEX IF NOT EXISTS idx_knowledge_faqs_agency_topic_active
  ON public.knowledge_faqs (agency_id, topic_key, is_active);

DROP TRIGGER IF EXISTS set_updated_at_knowledge_faqs ON public.knowledge_faqs;
CREATE TRIGGER set_updated_at_knowledge_faqs
  BEFORE UPDATE ON public.knowledge_faqs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.knowledge_faqs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_delete_knowledge_faqs ON public.knowledge_faqs;
CREATE POLICY admin_delete_knowledge_faqs
  ON public.knowledge_faqs
  FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text, 'manager'::text])
        AND u.agency_id = knowledge_faqs.agency_id
        AND u.is_active = true
    )
  );

DROP POLICY IF EXISTS admin_insert_knowledge_faqs ON public.knowledge_faqs;
CREATE POLICY admin_insert_knowledge_faqs
  ON public.knowledge_faqs
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text, 'manager'::text])
        AND u.agency_id = knowledge_faqs.agency_id
        AND u.is_active = true
    )
  );

DROP POLICY IF EXISTS admin_update_knowledge_faqs ON public.knowledge_faqs;
CREATE POLICY admin_update_knowledge_faqs
  ON public.knowledge_faqs
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text, 'manager'::text])
        AND u.agency_id = knowledge_faqs.agency_id
        AND u.is_active = true
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = ANY (ARRAY['owner'::text, 'manager'::text])
        AND u.agency_id = knowledge_faqs.agency_id
        AND u.is_active = true
    )
  );

DROP POLICY IF EXISTS team_read_knowledge_faqs ON public.knowledge_faqs;
CREATE POLICY team_read_knowledge_faqs
  ON public.knowledge_faqs
  FOR SELECT
  TO authenticated
  USING (
    agency_id IN (
      SELECT u.agency_id FROM public.users u
      WHERE u.auth_user_id = auth.uid()
    )
    AND (
      is_agency_admin()
      OR (status = 'approved' AND is_active = true)
    )
  );

-- Safety table: raw page-content snapshot taken before any Knowledge & FAQ
-- block on a manual page is replaced with a {{faq: topic_key}} marker.
CREATE TABLE IF NOT EXISTS public.manuals_faq_extraction_backup (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manual_id         uuid NOT NULL REFERENCES public.manuals(id),
  original_content  text NOT NULL,
  extracted_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.manuals_faq_extraction_backup ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_delete_manuals_faq_extraction_backup ON public.manuals_faq_extraction_backup;
CREATE POLICY admin_delete_manuals_faq_extraction_backup
  ON public.manuals_faq_extraction_backup
  FOR DELETE
  TO authenticated
  USING (is_agency_admin());

DROP POLICY IF EXISTS admin_insert_manuals_faq_extraction_backup ON public.manuals_faq_extraction_backup;
CREATE POLICY admin_insert_manuals_faq_extraction_backup
  ON public.manuals_faq_extraction_backup
  FOR INSERT
  TO authenticated
  WITH CHECK (is_agency_admin());

DROP POLICY IF EXISTS admin_update_manuals_faq_extraction_backup ON public.manuals_faq_extraction_backup;
CREATE POLICY admin_update_manuals_faq_extraction_backup
  ON public.manuals_faq_extraction_backup
  FOR UPDATE
  TO authenticated
  USING (is_agency_admin())
  WITH CHECK (is_agency_admin());

DROP POLICY IF EXISTS admin_read_manuals_faq_extraction_backup ON public.manuals_faq_extraction_backup;
CREATE POLICY admin_read_manuals_faq_extraction_backup
  ON public.manuals_faq_extraction_backup
  FOR SELECT
  TO authenticated
  USING (is_agency_admin());
