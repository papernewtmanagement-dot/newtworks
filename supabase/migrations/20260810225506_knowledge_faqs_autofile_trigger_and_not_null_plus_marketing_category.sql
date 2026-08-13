-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 22:55:06 UTC (ledger name: knowledge_faqs_autofile_trigger_and_not_null_plus_marketing_category) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810225506.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 1. Marketing is not a line of business, so line_group needs a home for it.
ALTER TABLE public.knowledge_faq_categories DROP CONSTRAINT IF EXISTS knowledge_faq_categories_line_group_chk;
ALTER TABLE public.knowledge_faq_categories ADD CONSTRAINT knowledge_faq_categories_line_group_chk
  CHECK (line_group IN ('foundational','personal_insurance','financial_services','commercial','marketing','unsorted'));

INSERT INTO public.knowledge_faq_categories (agency_id, slug, label, line_group, is_state_farm, generic_slug, sort_order)
VALUES
 ('126794dd-25ff-47d2-a436-724499733365','marketing','Marketing & Lead Response','marketing',false,NULL,600),
 ('126794dd-25ff-47d2-a436-724499733365','sf_marketing','SF Marketing & Lead Response','marketing',true,'marketing',1600),
 ('126794dd-25ff-47d2-a436-724499733365','unsorted','Unsorted','unsorted',false,NULL,9000)
ON CONFLICT (agency_id, slug) DO NOTHING;

-- 2. Derive category from product_line so an insert never has to supply it.
CREATE OR REPLACE FUNCTION public.derive_faq_category(p_product_line text, p_topic_key text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN p_product_line ILIKE '%earthquake%' THEN 'sf_earthquake'
    WHEN p_product_line ILIKE '%personal articles%' THEN 'sf_personal_articles'
    WHEN p_product_line ILIKE '%umbrella%' THEN 'sf_umbrella'
    WHEN p_product_line ILIKE '%trupanion%' OR p_product_line ILIKE '%pet%' THEN 'sf_pet'
    WHEN p_product_line ILIKE '%flood%' THEN 'sf_flood'
    WHEN p_product_line ILIKE '%FCB%' OR p_product_line ILIKE '%long-term care%'
      OR p_product_line ILIKE '%long term care%' THEN 'sf_long_term_care'
    WHEN p_product_line ILIKE '%medicare%' THEN 'sf_medicare'
    WHEN p_product_line ILIKE '%annuit%' THEN 'sf_annuities'
    WHEN p_product_line ILIKE '%disability%' THEN 'sf_disability_income'
    WHEN p_product_line ILIKE '%boat%' OR p_product_line ILIKE '%motorcycle%'
      OR p_product_line ILIKE '%watercraft%' OR p_product_line ILIKE '%recreational%' THEN 'sf_powersports'
    WHEN p_product_line ILIKE '%commercial%' OR p_product_line ILIKE '%business%' THEN 'sf_commercial_fire'
    WHEN p_product_line ILIKE '%workers%' THEN 'sf_workers_comp'
    -- Auto coverage letters and auto-specific benefits
    WHEN p_product_line ILIKE '%Coverage G%' OR p_product_line ILIKE '%Coverage D%'
      OR p_product_line ILIKE '%Coverage M%' OR p_product_line ILIKE '%Coverage R1%'
      OR p_product_line ILIKE '%Coverage H%' OR p_product_line ILIKE '%Coverage U%'
      OR p_product_line ILIKE '%Coverage S%' OR p_product_line ILIKE '%Coverage P%'
      OR p_product_line ILIKE '%collision%' OR p_product_line ILIKE '%comprehensive%'
      OR p_product_line ILIKE '%roadside%' OR p_product_line ILIKE '%uninsured%'
      OR p_product_line ILIKE '%injury protection%' OR p_product_line ILIKE '%car rental%'
      OR p_product_line ILIKE '%dismemberment%' THEN 'sf_auto'
    -- Property endorsements and dwelling items
    WHEN p_product_line ILIKE '%sewer%' OR p_product_line ILIKE '%drain%'
      OR p_product_line ILIKE '%dwelling%' OR p_product_line ILIKE '%roof%'
      OR p_product_line ILIKE '%water%' OR p_product_line ILIKE '%seepage%'
      OR p_product_line ILIKE '%service line%' OR p_product_line ILIKE '%home systems%'
      OR p_product_line ILIKE '%energy efficiency%' OR p_product_line ILIKE '%siding%' THEN 'sf_fire'
    -- Fall back on the topic_key prefix, which extraction sets reliably
    WHEN p_topic_key LIKE 'auto%' OR p_topic_key LIKE 'pip%' THEN 'sf_auto'
    WHEN p_topic_key LIKE 'liability%' THEN 'sf_umbrella'
    WHEN p_topic_key LIKE 'water%' OR p_topic_key LIKE 'upgrade%' THEN 'sf_fire'
    WHEN p_topic_key LIKE 'retirement_insurance%' THEN 'sf_long_term_care'
    ELSE 'unsorted'
  END;
$fn$;

-- 3. Fill category, difficulty and visibility on insert so nothing lands hidden
--    and nothing needs Peter's per-row approval.
CREATE OR REPLACE FUNCTION public.autofile_knowledge_faq()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.category IS NULL OR btrim(NEW.category) = '' THEN
    NEW.category := public.derive_faq_category(COALESCE(NEW.product_line,''), COALESCE(NEW.topic_key,''));
  END IF;

  IF NEW.difficulty IS NULL OR btrim(NEW.difficulty) = '' THEN
    NEW.difficulty := 'intermediate';
  END IF;

  -- Auto-publish on insert. Peter can still set a row back to draft afterward;
  -- this trigger is INSERT-only and never overrides a later manual change.
  IF NEW.status IS NULL OR NEW.status = 'draft' THEN
    NEW.status := 'approved';
    NEW.is_active := true;
    NEW.approved_at := COALESCE(NEW.approved_at, now());
  END IF;

  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_autofile_knowledge_faq ON public.knowledge_faqs;
CREATE TRIGGER trg_autofile_knowledge_faq
  BEFORE INSERT ON public.knowledge_faqs
  FOR EACH ROW EXECUTE FUNCTION public.autofile_knowledge_faq();

-- 4. Backstop: with the trigger filling them, these can never be null.
UPDATE public.knowledge_faqs
SET category = public.derive_faq_category(COALESCE(product_line,''), COALESCE(topic_key,''))
WHERE category IS NULL OR btrim(category) = '';
UPDATE public.knowledge_faqs SET difficulty = 'intermediate'
WHERE difficulty IS NULL OR btrim(difficulty) = '';

ALTER TABLE public.knowledge_faqs ALTER COLUMN category SET NOT NULL;
ALTER TABLE public.knowledge_faqs ALTER COLUMN difficulty SET NOT NULL;

ALTER TABLE public.knowledge_faqs DROP CONSTRAINT IF EXISTS knowledge_faqs_difficulty_chk;
ALTER TABLE public.knowledge_faqs ADD CONSTRAINT knowledge_faqs_difficulty_chk
  CHECK (difficulty IN ('basic','intermediate','advanced'));
