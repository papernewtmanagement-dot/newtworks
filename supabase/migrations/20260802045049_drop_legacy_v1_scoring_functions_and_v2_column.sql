-- Step 8: drop the 13 legacy v1 scoring functions. Confirmed safe: the
-- v1-assessment edge fn was rewritten (commit 12b048e) to remove all v1
-- handlers and the v2 branch, and no other DB function calls any of these
-- (verified via pg_get_functiondef grep before this migration).
DROP FUNCTION IF EXISTS public.apply_newtworks_v1_lss_to_candidate(uuid);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_bands(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_cognitive_score(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_distortion_signals(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_expansion_triggers(uuid, jsonb, integer, integer, integer, numeric);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_impression_mgmt_score(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_nonsense_inflation(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_reliability_per_candidate(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_reliability_population(uuid, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_traits(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.compute_newtworks_v1_traits_as_row(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.hiregauge_lss_delta_v1(hiring_candidates, jsonb, jsonb);

-- Step 9: drop hiring_candidates.v2. Confirmed safe: no frontend file
-- (CandidateDetail.jsx, CandidateAssessment.jsx, Team.jsx) reads or writes
-- .v2, no DB function reads/writes the column, and the edge fn no longer
-- branches on it (see commit 12b048e).
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS v2;
