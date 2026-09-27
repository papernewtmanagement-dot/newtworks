-- 2026-09-27: never close someone who is still working on the assessment.
-- Alexandra Smithwick finished the ranking section at 2:21 PM on 2026-09-15 and
-- was closed as "assessment not taken" that night because her first invite was
-- more than 14 days old. The clock now also waits until her last answer is
-- p_days old.
CREATE OR REPLACE FUNCTION public.close_stale_assessment_sent(p_agency_id uuid, p_recipe_id uuid, p_days integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- 2026-09-26: counts from the first invite of the CURRENT round
-- (hiring_candidates.assessment_round_started_at), not the first invite ever.
-- A candidate reopened to Applied would otherwise be re-declined on the next
-- run because their original invite was long past the window.
-- 2026-09-27: also skips anyone who answered an assessment question within
-- the window, so a candidate partway through is never closed mid-assessment.
DECLARE
  v_closed int := 0;
BEGIN
  WITH first_inv AS (
    SELECT ai.candidate_id, min(ai.sent_at) AS first_sent
    FROM public.assessment_invitations ai
    JOIN public.hiring_candidates h ON h.id = ai.candidate_id
    WHERE ai.agency_id = p_agency_id
      AND ai.sent_at >= COALESCE(h.assessment_round_started_at, '-infinity'::timestamptz)
    GROUP BY ai.candidate_id
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
       AND NOT EXISTS (
         SELECT 1 FROM public.hiregauge_candidate_responses r
          WHERE r.candidate_id = hc.id
            AND r.answered_at >= NOW() - (p_days || ' days')::interval
       )
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
