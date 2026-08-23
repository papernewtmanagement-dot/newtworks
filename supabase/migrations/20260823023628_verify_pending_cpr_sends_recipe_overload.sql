-- run_internal_recipe always calls a handler as public.<name>(agency_id, recipe_id).
-- public.verify_pending_cpr_sends() takes zero arguments, so the recipe could never
-- dispatch: the existence guard checks proname only, passes, then EXECUTE fails on
-- the signature. Add a 2-arg overload that delegates, rather than changing the
-- working zero-arg function that other callers may use directly.
CREATE OR REPLACE FUNCTION public.verify_pending_cpr_sends(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  -- The zero-arg body pins the agency and looks its own recipe row up by name,
  -- so both parameters are accepted for the dispatcher's sake and not forwarded.
  v_result := public.verify_pending_cpr_sends();

  -- automation-runner reads these two keys off the RPC result for its run log.
  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'confirmed')::int, 0)
                       + COALESCE((v_result->>'verify_dispatched')::int, 0)
                       + COALESCE((v_result->>'reset_error')::int, 0)
                       + COALESCE((v_result->>'reset_stale')::int, 0)
                       + COALESCE((v_result->>'escalated')::int, 0),
    'output_summary', COALESCE(v_result->>'note',
        COALESCE(v_result->>'confirmed','0')         || ' confirmed, '   ||
        COALESCE(v_result->>'verify_dispatched','0') || ' verifying, '   ||
        COALESCE(v_result->>'still_pending','0')     || ' still pending, '||
        COALESCE(v_result->>'reset_error','0')       || ' reset on error, '||
        COALESCE(v_result->>'reset_stale','0')       || ' reset stale, ' ||
        COALESCE(v_result->>'escalated','0')         || ' escalated')
  );
END;
$function$;
