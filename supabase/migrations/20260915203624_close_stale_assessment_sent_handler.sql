-- Closes candidates who were invited to the assessment and never took it.
-- Owns the candidate row; the invitation rows are owned by
-- send_v1_assessment_invitations, which marks them no_response separately.
-- p_days lets the window be read from the recipe rather than hard-coded twice.
CREATE OR REPLACE FUNCTION public.close_stale_assessment_sent(
  p_agency_id uuid,
  p_recipe_id uuid,
  p_days int DEFAULT 14
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_closed int := 0;
BEGIN
  WITH first_inv AS (
    SELECT candidate_id, min(sent_at) AS first_sent
    FROM public.assessment_invitations
    WHERE agency_id = p_agency_id
    GROUP BY candidate_id
  ),
  closed AS (
    UPDATE public.hiring_candidates hc
       SET status = 'declined',
           decline_reason = 'assessment_not_taken'
      FROM first_inv f
     WHERE f.candidate_id = hc.id
       AND hc.agency_id = p_agency_id
       AND hc.status = 'assessment_sent'
       AND hc.is_test_candidate IS NOT TRUE
       AND hc.assessment_completed_at IS NULL
       AND hc.decision_at IS NULL
       AND f.first_sent < NOW() - (p_days || ' days')::interval
    RETURNING 1
  )
  SELECT count(*) INTO v_closed FROM closed;

  RETURN jsonb_build_object(
    'closed', v_closed,
    'window_days', p_days,
    'ran_at', NOW(),
    'records_processed', v_closed,
    'output_summary', v_closed || ' candidate(s) closed after ' || p_days ||
      ' days with no assessment taken'
  );
END;
$function$;
