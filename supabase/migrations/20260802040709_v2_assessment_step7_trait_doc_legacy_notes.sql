-- v2 assessment Step 7 — trait documentation cleanup, per origin-thread
-- decision: KEEP all 10 non-active-roster rows (3 composite constructs
-- Step 4 builds scoring for, plus 7 legacy v1 trait labels that document
-- 53 historical candidates' real stored scores). Nothing deleted.
--
-- Added signal: append a retirement notice to construct_notes on the 7
-- legacy v1 rows so a reader of a historical score knows the label is
-- retired and not part of the current instrument. Existing match_status
-- values (accurate audit history from the Ass Fix 4 label-content
-- mismatch audit) are left untouched.
UPDATE public.hiregauge_trait_documentation
SET construct_notes = COALESCE(construct_notes || E'\n\n', '') ||
  'LEGACY v1 TRAIT — retired from active assessment 2026-08-01. Column retained on hiring_candidates for the 53 historical candidates scored under v1. Not measured by the current instrument. Do not use for new hiring decisions.',
  updated_at = now()
WHERE trait_name IN ('analytical','belief_in_others','deadline_motivation','independent_spirit','optimism','recognition_drive','self_promotion');
