-- Add 'excerpt' as a valid manual_type. Excerpt rows are named-fragment sources
-- referenced by [Embedded excerpt from: X] markers on other pages. Hidden from
-- tree UI; only surface via the resolveExcerpt mdToHtml pipeline.
ALTER TABLE public.manuals DROP CONSTRAINT IF EXISTS manuals_manual_type_check;
ALTER TABLE public.manuals ADD CONSTRAINT manuals_manual_type_check
  CHECK (manual_type = ANY (ARRAY[
    'handbook'::text,
    'processes'::text,
    'admin'::text,
    'roleplaying'::text,
    'financial_literacy'::text,
    'investments'::text,
    'excerpt'::text
  ]));
