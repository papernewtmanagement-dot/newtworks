-- Fix: _assessment_distortion_severity was wrongly dropped in step 2 -- it IS
-- still a live dependency of the SHARED (not old-only) function
-- _assessment_dampen_trait_by_distortion, which the NEW-path
-- _newtworks_competency_composite calls for compassion / dispositional_optimism
-- dampening. Caught by smoke test before shipping. Restoring byte-identical
-- body (traced via supabase_migrations.schema_migrations / repo history back
-- to the pre-rename _cts_distortion_severity, migration 20260716174221 --
-- the 20260724 rename migration copied this body verbatim under the new name).
CREATE OR REPLACE FUNCTION public._assessment_distortion_severity(p_distortion text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_distortion
    WHEN 'high' THEN 1.0
    WHEN 'moderate' THEN 0.6
    ELSE 0.0
  END::numeric;
$$;

COMMENT ON FUNCTION public._assessment_distortion_severity(text) IS
'0.0 (LOW distortion) to 1.0 (HIGH). Scales targeted ceiling dampening of socially-desirable traits. Restored 2026-08-06 after being wrongly dropped as "old-path-only" -- it is shared machinery, called by _assessment_dampen_trait_by_distortion which the new-instrument competency composite also uses.';
