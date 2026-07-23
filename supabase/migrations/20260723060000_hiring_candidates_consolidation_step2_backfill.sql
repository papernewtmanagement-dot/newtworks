-- Step 2 of the hiring_candidates consolidation (approved 2026-07-23).
-- Backfill the 3 new jsonb columns (assessment_timing, ai_analysis, interview_analysis)
-- from their flat source columns. Read-only against the old columns, writes only into
-- the new. Idempotent: WHERE clauses guard against updating rows that have no source data.

-- 1. assessment_timing ← 9 timing columns (cts/epq/lss/vct started_at + completed_at, plus cts_invited_at).
--    Wall-duration columns (cts_wall_duration_seconds etc.) NOT copied — those are derived, not stored.
UPDATE public.hiring_candidates
SET assessment_timing = jsonb_strip_nulls(jsonb_build_object(
  'invited_at', cts_invited_at,
  'cts', NULLIF(jsonb_strip_nulls(jsonb_build_object(
    'started_at',   cts_started_at,
    'completed_at', cts_completed_at
  )), '{}'::jsonb),
  'epq', NULLIF(jsonb_strip_nulls(jsonb_build_object(
    'started_at',   epq_started_at,
    'completed_at', epq_completed_at
  )), '{}'::jsonb),
  'lss', NULLIF(jsonb_strip_nulls(jsonb_build_object(
    'started_at',   lss_started_at,
    'completed_at', lss_completed_at
  )), '{}'::jsonb),
  'vct', NULLIF(jsonb_strip_nulls(jsonb_build_object(
    'started_at',   vct_started_at,
    'completed_at', vct_completed_at
  )), '{}'::jsonb)
))
WHERE cts_invited_at    IS NOT NULL
   OR cts_started_at    IS NOT NULL OR cts_completed_at IS NOT NULL
   OR epq_started_at    IS NOT NULL OR epq_completed_at IS NOT NULL
   OR lss_started_at    IS NOT NULL OR lss_completed_at IS NOT NULL
   OR vct_started_at    IS NOT NULL OR vct_completed_at IS NOT NULL;

-- 2. ai_analysis ← 10 gt_* columns.
UPDATE public.hiring_candidates
SET ai_analysis = jsonb_strip_nulls(jsonb_build_object(
  'archetype',              gt_archetype,
  'best_fit_seat',          gt_best_fit_seat,
  'alt_seats',              CASE WHEN gt_alt_seats IS NOT NULL THEN to_jsonb(gt_alt_seats) ELSE NULL END,
  'decline_category',       gt_decline_category,
  'coaching_variant',       gt_coaching_variant,
  'motivator_family',       gt_motivator_family,
  'character_floor_status', gt_character_floor_status,
  'confidence',             gt_confidence,
  'notes',                  gt_extraction_notes,
  'extracted_at',           gt_extracted_at
))
WHERE gt_archetype              IS NOT NULL OR gt_best_fit_seat  IS NOT NULL
   OR gt_alt_seats              IS NOT NULL OR gt_decline_category IS NOT NULL
   OR gt_coaching_variant       IS NOT NULL OR gt_motivator_family IS NOT NULL
   OR gt_character_floor_status IS NOT NULL OR gt_confidence      IS NOT NULL
   OR gt_extraction_notes       IS NOT NULL OR gt_extracted_at    IS NOT NULL;

-- 3. interview_analysis ← iv_verdict, iv_verdict_reason, interview_analysis_text, timestamps.
--    Composite + scores snapshotted at analysis time by pulling from v_hiring_candidates
--    (which computes iv_nature/nurture/drivers/composite from interview_answers).
UPDATE public.hiring_candidates hc
SET interview_analysis = jsonb_strip_nulls(jsonb_build_object(
  'verdict',        hc.iv_verdict,
  'verdict_reason', hc.iv_verdict_reason,
  'composite',      vh.iv_composite,
  'scores',         NULLIF(jsonb_strip_nulls(jsonb_build_object(
    'nature',  vh.iv_nature,
    'nurture', vh.iv_nurture,
    'drivers', vh.iv_drivers
  )), '{}'::jsonb),
  'narrative',      hc.interview_analysis_text,
  'analyzed_at',    COALESCE(hc.interview_analysis_at, hc.iv_scored_at)
))
FROM public.v_hiring_candidates vh
WHERE hc.id = vh.id
  AND (hc.iv_verdict             IS NOT NULL
    OR hc.iv_verdict_reason      IS NOT NULL
    OR hc.iv_scored_at           IS NOT NULL
    OR hc.interview_analysis_text IS NOT NULL
    OR hc.interview_analysis_at   IS NOT NULL);
