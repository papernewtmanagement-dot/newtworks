-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 19:01:34 UTC (ledger name: fit_conversations_parent_use_shared_fragments) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810190134.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- FIT Conversations parent: Customize & Close section rebuilt on shared fragments;
-- Next Steps + Review & Referral inline copies replaced with their fragments.

-- (a) Customize & Close section -> three markers
UPDATE public.manuals
SET content = left(content, position('## Customize & Close' in content) - 1)
  || $blk$*[Embedded excerpt from: Customize Header]*

*[Embedded excerpt from: One Simple Price]*

*[Embedded excerpt from: Great Fit Check]*

$blk$
  || substring(content from position('### Answering objections' in content)),
version = version + 1, updated_at = now()
WHERE id = 'c129f8b1-c128-4699-84b4-301cf9df0946'
  AND position('## Customize & Close' in content) > 0
  AND position('### Answering objections' in content) > 0;

-- (b) Review & Referral inline copy -> fragment marker
UPDATE public.manuals
SET content = left(content, position('## Get a Review & Referral' in content) - 1)
  || '*[Embedded excerpt from: Review & Referral]*' || chr(10),
version = version + 1, updated_at = now()
WHERE id = 'c129f8b1-c128-4699-84b4-301cf9df0946'
  AND position('## Get a Review & Referral' in content) > 0;

-- (c) Answering objections: second line is a qualifier of the first -> sub-bullet
UPDATE public.manuals
SET content = replace(content,
$old$- An objection now reveals improvement needed earlier
- But sometimes they aren't objecting--just looking for help with their concerns$old$,
$new$- An objection now reveals improvement needed earlier
  - But sometimes they aren't objecting--just looking for help with their concerns$new$),
version = version + 1, updated_at = now()
WHERE id = 'c129f8b1-c128-4699-84b4-301cf9df0946';

-- (d) Set FU / Next Steps heading -> fragment marker
UPDATE public.manuals
SET content = replace(content, '## Set FU / Next Steps', '*[Embedded excerpt from: Next Steps]*'),
version = version + 1, updated_at = now()
WHERE id = 'c129f8b1-c128-4699-84b4-301cf9df0946';
