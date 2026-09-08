-- =========================================================================
-- CTS invite: Peter's wording, cleaner subject, one-time backfill switch
-- (2026-09-08, same session as 20260908151813)
-- =========================================================================
-- Peter rewrote the answer-honestly line. Two fixes found while preparing
-- the backfill of the 17 candidates already in 'interview': most of them
-- have no position on file (subject read "for the role at..."), and one had
-- already sat her interview, so "finish it before your interview" was wrong
-- for her. Closing line now keys off interview_scheduled_start.
--
-- p_backfill (default false) skips the go-live line for a one-time direct
-- call. The recipe runner passes two arguments, so it always runs with the
-- default. The old two-argument signature is dropped first so the runner's
-- SELECT public.send_cts_sales_profile_invites($1, $2) stays unambiguous.
-- =========================================================================

DROP FUNCTION IF EXISTS public.send_cts_sales_profile_invites(uuid, uuid);

CREATE OR REPLACE FUNCTION public.send_cts_sales_profile_invites(
  p_agency_id uuid,
  p_recipe_id uuid,
  p_backfill  boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- Internal automation handler (run_internal_recipe). Sends the CTS Sales
-- Profile registration link to candidates who finished the Newtworks
-- assessment at least one hour ago and were advanced past it. One send per
-- candidate, stamped on hiring_candidates.cts_invite_sent_at. Same Gmail
-- path as the assessment invites (composio_send_email -> pg_net).
-- p_backfill=true ignores the go-live line (recipe created_at); one-time use.
DECLARE
  v_url            text;
  v_live_since     timestamptz;
  v_max_per_run    int := 10;
  v_sent           int := 0;
  v_errors         int := 0;
  v_error_details  jsonb := '[]'::jsonb;
  v_sent_ids       uuid[] := ARRAY[]::uuid[];
  v_cand           RECORD;
  v_subject        text;
  v_closing        text;
  v_html           text;
  v_pg_net_id      bigint;
BEGIN
  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cts_sales_profile_register_url';

  IF v_url IS NULL OR btrim(v_url) = '' THEN
    RETURN jsonb_build_object(
      'sent', 0, 'errors', 0, 'ran_at', NOW(), 'records_processed', 0,
      'output_summary', 'cts_sales_profile_register_url setting is blank, nothing sent');
  END IF;

  -- Go-live line. Candidates who finished before this recipe row existed are
  -- not picked up by the hourly run. Read from the recipe itself so there is
  -- no magic date here. p_backfill lifts it for a one-time direct call.
  IF p_backfill THEN
    v_live_since := '-infinity'::timestamptz;
  ELSE
    SELECT created_at INTO v_live_since
    FROM public.automation_recipes WHERE id = p_recipe_id;
    IF v_live_since IS NULL THEN v_live_since := NOW(); END IF;
  END IF;

  FOR v_cand IN
    SELECT hc.id, hc.first_name, hc.email, hc.position, hc.interview_scheduled_start
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.is_test_candidate IS NOT TRUE
      AND hc.cts_invite_sent_at IS NULL
      AND hc.assessment_completed_at IS NOT NULL
      AND hc.assessment_completed_at >= v_live_since
      AND hc.assessment_completed_at <= NOW() - INTERVAL '1 hour'
      -- Advanced past the assessment verdict. 'assessed' is deliberately
      -- left out: it means the verdict has not run (or the scheduler failed),
      -- and a would-be decline must not get a CTS.
      AND hc.status IN ('interview', 'meet_and_greet', 'offer', 'reference_check')
      AND hc.decision_at IS NULL
      AND hc.assessment_exit_gate IS NULL
      AND hc.email IS NOT NULL
      AND hc.email <> ''
    ORDER BY hc.assessment_completed_at
    LIMIT v_max_per_run
  LOOP
    BEGIN
      v_subject := 'Next step: sales profile assessment' ||
                   CASE WHEN NULLIF(v_cand.position, '') IS NOT NULL
                        THEN ' for ' || v_cand.position ELSE '' END ||
                   ' at Peter Story State Farm';

      v_closing := CASE
        WHEN v_cand.interview_scheduled_start IS NOT NULL
         AND v_cand.interview_scheduled_start < NOW()
          THEN 'Please finish it in the next few days so I have it alongside your assessment results.'
        ELSE 'Please finish it before your interview so we can talk through both sets of results together.'
      END;

      v_html :=
        '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
        '<p>Thanks for finishing the assessment. I appreciate the time you put in.</p>' ||
        '<p>There is one more step in the process. It is a short sales profile called the CTS. ' ||
          'It takes about 25 minutes and there is nothing to prepare. ' ||
          'Answer honestly with the first reaction that comes to mind. This will give you a ' ||
          'good understanding of whether this role will inspire you or stress you.</p>' ||
        '<p><a href="' || v_url || '" style="display:inline-block;padding:12px 24px;' ||
          'background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;' ||
          'font-weight:600;">Start the sales profile</a></p>' ||
        '<p style="color:#64748b;font-size:13px;">The link will have you register first, then it starts. ' ||
          'If the button does not work, paste this link into your browser:<br>' ||
          '<a href="' || v_url || '">' || v_url || '</a></p>' ||
        '<p>' || v_closing || '</p>' ||
        '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';

      v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

      UPDATE public.hiring_candidates
      SET cts_invite_sent_at = NOW(), cts_invite_pg_net_id = v_pg_net_id
      WHERE id = v_cand.id;

      v_sent := v_sent + 1;
      v_sent_ids := array_append(v_sent_ids, v_cand.id);
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object(
        'candidate_id', v_cand.id, 'error', SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'errors', v_errors,
    'error_details', v_error_details,
    'sent_candidate_ids', to_jsonb(v_sent_ids),
    'backfill', p_backfill,
    'ran_at', NOW(),
    'records_processed', v_sent,
    'output_summary', v_sent || ' CTS invite(s) sent, ' || v_errors || ' error(s)');
END;
$function$;
