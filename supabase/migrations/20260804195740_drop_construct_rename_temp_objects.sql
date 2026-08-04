-- Cleanup after the construct rename. Peter approved 2026-08-04.
-- Both objects existed only to prove the rename moved no numbers. That check has
-- passed (195 candidates, zero drift on every field) and the deploy is live, so
-- they have no further purpose. Hard DELETE, not archive, per Peter's standing rule.
--
-- zz_construct_rename_baseline_20260804 was the pre-rename verdict_overall snapshot.
-- hiring_candidates_interview_answers_bak_20260804 was the pre-rename copy of the one
-- candidate row whose stored score keys were rewritten. The rewrite is verified and the
-- migration that performed it is mirrored in supabase/migrations, so the transformation
-- is reproducible from source control without this table.

DROP TABLE IF EXISTS public.zz_construct_rename_baseline_20260804;
DROP TABLE IF EXISTS public.hiring_candidates_interview_answers_bak_20260804;
