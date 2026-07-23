-- Step 1 of the hiring_candidates consolidation (approved 2026-07-23).
-- Additive only — three brand-new jsonb columns. No renames, no drops, no data changes.
-- Follow-on migrations will backfill from source columns, update the view + functions
-- to read from the new columns, then drop the old flat columns.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_timing jsonb,
  ADD COLUMN IF NOT EXISTS ai_analysis jsonb,
  ADD COLUMN IF NOT EXISTS interview_analysis jsonb;

COMMENT ON COLUMN public.hiring_candidates.assessment_timing IS
  'Per-phase assessment timing. Shape: {invited_at, cts:{started_at,completed_at}, epq:{...}, lss:{...}, vct:{...}}. Replaces 12 flat phase-timing columns (cts_invited_at, cts_started_at, cts_completed_at, epq_started_at, epq_completed_at, lss_started_at, lss_completed_at, vct_started_at, vct_completed_at, cts_wall_duration_seconds, lss_wall_duration_seconds, vct_wall_duration_seconds) once backfill and cutover complete. Durations computed on demand via helper function, not stored.';

COMMENT ON COLUMN public.hiring_candidates.ai_analysis IS
  'AI-produced analysis output. Shape: {archetype, best_fit_seat, alt_seats, decline_category, coaching_variant, motivator_family, character_floor_status, confidence, notes, extracted_at}. Replaces the 10 gt_* columns once backfill and cutover complete.';

COMMENT ON COLUMN public.hiring_candidates.interview_analysis IS
  'Interview verdict synthesis. Shape: {verdict, verdict_reason, composite, scores:{nature,nurture,drivers}, narrative, analyzed_at}. Replaces interview_analysis_text, interview_analysis_at, iv_verdict, iv_verdict_reason, iv_scored_at once backfill and cutover complete.';
