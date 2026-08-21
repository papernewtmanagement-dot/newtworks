-- ============================================================
-- Step 7A: backfill 3 wall_duration_seconds flat cols into
-- assessment_timing jsonb. Idempotent (skips rows already mirrored).
-- Prep for 7B col drops.
-- ============================================================

UPDATE public.hiring_candidates
SET assessment_timing = COALESCE(assessment_timing,'{}'::jsonb)
  || jsonb_build_object(
       'cts', COALESCE(assessment_timing->'cts','{}'::jsonb)
              || jsonb_build_object('wall_duration_seconds', cts_wall_duration_seconds)
     )
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND cts_wall_duration_seconds IS NOT NULL
  AND (assessment_timing->'cts'->>'wall_duration_seconds') IS NULL;

UPDATE public.hiring_candidates
SET assessment_timing = COALESCE(assessment_timing,'{}'::jsonb)
  || jsonb_build_object(
       'lss', COALESCE(assessment_timing->'lss','{}'::jsonb)
              || jsonb_build_object('wall_duration_seconds', lss_wall_duration_seconds)
     )
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND lss_wall_duration_seconds IS NOT NULL
  AND (assessment_timing->'lss'->>'wall_duration_seconds') IS NULL;

UPDATE public.hiring_candidates
SET assessment_timing = COALESCE(assessment_timing,'{}'::jsonb)
  || jsonb_build_object(
       'vct', COALESCE(assessment_timing->'vct','{}'::jsonb)
              || jsonb_build_object('wall_duration_seconds', vct_wall_duration_seconds)
     )
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND vct_wall_duration_seconds IS NOT NULL
  AND (assessment_timing->'vct'->>'wall_duration_seconds') IS NULL;
