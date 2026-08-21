-- Add an overload that matches run_internal_recipe's calling convention:
-- public.<handler>(agency_id uuid, recipe_id uuid) -> jsonb
-- The recipe_id is ignored (we don't need it; runner uses it only for logging).
-- Internally we delegate to the existing implementation with p_dry_run=FALSE.

CREATE OR REPLACE FUNCTION public.payroll_gl_writer(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Recipe-driven invocation: always live, never dry-run
  RETURN public.payroll_gl_writer(p_agency_id, FALSE);
END;
$$;

COMMENT ON FUNCTION public.payroll_gl_writer(uuid, uuid) IS
'Recipe-runner compatible overload. Called by run_internal_recipe with (agency_id, recipe_id). Delegates to payroll_gl_writer(agency_id, p_dry_run=FALSE).';
