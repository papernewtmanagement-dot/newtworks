-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 23:53:37 UTC (ledger name: hiring_candidates_assessment_date_nullable) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801235337.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- assessment_date was NOT NULL with no default, which meant every
-- candidate-creation path had to supply a value even before any
-- assessment was taken. Two intake webhooks (Indeed, ZipRecruiter) were
-- working around this by stamping the INTAKE date, not the actual
-- assessment date -- factually wrong data (a candidate who never takes
-- the assessment still shows an assessment_date). The correct semantics:
-- assessment_date is null until the assessment is actually completed,
-- at which point handleFinalize/handleFinalizeV2 in the v1-assessment
-- edge function already sets it correctly. Making the column nullable
-- fixes both the insert-blocking bug and removes the need for the
-- webhook workaround (companion code fix in the same commit).
ALTER TABLE public.hiring_candidates
  ALTER COLUMN assessment_date DROP NOT NULL;

COMMENT ON COLUMN public.hiring_candidates.assessment_date IS
  'Date the assessment was completed. NULL until actual completion -- set by v1-assessment edge function finalize logic (v1 or v2 path). Never stamp this at candidate intake/creation time.';
