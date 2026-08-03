-- Cleanup: retiring duplicate Step 2 normalization functions built in a
-- separate parallel pass. Step 2 was already completed and shipped as
-- hiregauge_v2_normalized_inputs(uuid) -- that is the canonical interface.
-- These three were redundant, never consumed by anything, dropped cleanly.
DROP FUNCTION IF EXISTS public._newtworks_sjt_topic_score(public.hiring_candidates, text);
DROP FUNCTION IF EXISTS public._newtworks_reasoning_score(public.hiring_candidates);
DROP FUNCTION IF EXISTS public._newtworks_competency_normalize(numeric, numeric);
