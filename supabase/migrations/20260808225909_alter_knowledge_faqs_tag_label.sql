ALTER TABLE public.knowledge_faqs
  DROP CONSTRAINT IF EXISTS knowledge_faqs_faq_type_check;
ALTER TABLE public.knowledge_faqs
  ADD COLUMN IF NOT EXISTS tag_label text NULL;
ALTER TABLE public.knowledge_faqs
  ALTER COLUMN faq_type DROP NOT NULL;
