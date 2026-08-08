-- finrebuild_f6_statement_gl_writer_recipe_wrapper
-- run_internal_recipe dynamically calls public.<internal_handler>(agency_id,
-- recipe_id) — a 2-arg wrapper matching that exact calling convention,
-- same pattern as the existing bank_gl_writer/cc_gl_writer/payroll_gl_writer
-- wrappers. Full-history dry run/backfill still available via the 5-arg form.
CREATE OR REPLACE FUNCTION public.statement_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.statement_gl_writer(p_agency_id, NULL::uuid, NULL::date, NULL::date, FALSE);
END;
$function$;