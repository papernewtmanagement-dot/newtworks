-- alter_knowledge_faqs_tag_label
-- Peter directive: faq_type's 5-value CHECK was invented and does not match
-- real tag words on the manual pages (Coverage, Endorsement, Option, etc.).
-- Replace with a free-text tag_label column, no CHECK. faq_type stays as a
-- dead nullable column for a possible later wave; never populated for now.

ALTER TABLE public.knowledge_faqs
  DROP CONSTRAINT IF EXISTS knowledge_faqs_faq_type_check;
ALTER TABLE public.knowledge_faqs
  ADD COLUMN IF NOT EXISTS tag_label text NULL;
ALTER TABLE public.knowledge_faqs
  ALTER COLUMN faq_type DROP NOT NULL;
