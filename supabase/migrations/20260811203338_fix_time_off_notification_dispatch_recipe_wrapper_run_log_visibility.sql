CREATE OR REPLACE FUNCTION public.time_off_notification_dispatch(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.time_off_notification_dispatch(p_agency_id);
  -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
  RETURN v_result || jsonb_build_object(
    'records_processed',
      COALESCE((v_result->>'vote_request_emails')::int, 0)
      + COALESCE((v_result->>'decision_emails')::int, 0),
    'output_summary',
      COALESCE((v_result->>'vote_request_emails')::int, 0) || ' vote-request email(s), ' ||
      COALESCE((v_result->>'vote_closed_processed')::int, 0) || ' vote(s) closed, ' ||
      COALESCE((v_result->>'decision_emails')::int, 0) || ' decision email(s)'
  );
END;
$function$;
