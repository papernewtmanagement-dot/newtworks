-- 2026-08-29 — Automatic decline notice to every declined candidate.
--
-- Peter directive: "All declined candidates should receive a positive and
-- encouraging email for any declination reason except when I select calibration
-- as the reason. The email should send automatically even when an assessment is
-- declined automatically."
--
-- SHAPE: a cron sweep, not a trigger on each decline path. There are five ways a
-- candidate reaches status='declined' today (manual button in CandidateDetail,
-- auto_decline_on_resume_score, auto_decline_on_assessment_score,
-- handle_assessment_invite_bounce, candidate_email_response_apply). A sweep
-- covers all five and any future sixth with one code path, one log, one place to
-- change the wording.

CREATE TABLE IF NOT EXISTS public.candidate_decline_notices (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id         uuid NOT NULL,
  candidate_id      uuid NOT NULL REFERENCES public.hiring_candidates(id) ON DELETE CASCADE,
  decline_reason    text,
  subject           text,
  sent_at           timestamptz NOT NULL DEFAULT NOW(),
  pg_net_request_id bigint,
  created_at        timestamptz NOT NULL DEFAULT NOW()
);

-- One notice per candidate, ever. This index IS the no-double-send guard.
CREATE UNIQUE INDEX IF NOT EXISTS candidate_decline_notices_candidate_uniq
  ON public.candidate_decline_notices (candidate_id);

ALTER TABLE public.candidate_decline_notices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS authenticated_read_candidate_decline_notices ON public.candidate_decline_notices;
CREATE POLICY authenticated_read_candidate_decline_notices
  ON public.candidate_decline_notices FOR SELECT TO authenticated
  USING (public.is_agency_admin());

-- Cutover stamp. The sweep only picks up candidates declined at or after this
-- moment, so switching the feature on does NOT mail the ~90 people already
-- sitting in the Declined view from weeks past.
INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'decline_notice_cutover_at',
  NOW()::text,
  'text',
  'Candidates declined before this timestamp are never sent an automatic decline notice. Set when the feature went live 2026-08-29.'
)
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.send_candidate_decline_notices(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sent            int := 0;
  v_errors          int := 0;
  v_max_per_run     int := 15;
  v_skipped_no_addr int := 0;
  v_skipped_unsure  int := 0;
  v_cand            RECORD;
  v_subject         text;
  v_html            text;
  v_role_phrase     text;
  v_pg_net_id       bigint;
  v_error_details   jsonb := '[]'::jsonb;
  v_cutover         timestamptz;
BEGIN
  SELECT setting_value::timestamptz INTO v_cutover
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'decline_notice_cutover_at';

  IF v_cutover IS NULL THEN
    RETURN jsonb_build_object(
      'error', 'decline_notice_cutover_at missing — refusing to send',
      'ran_at', NOW(), 'records_processed', 0,
      'output_summary', 'ERROR: settings.decline_notice_cutover_at missing — refusing to send');
  END IF;

  -- Reporting-only counts: declined since cutover, eligible by reason, but
  -- unreachable. Surfaced in the summary so silent skips stay visible.
  SELECT
    COUNT(*) FILTER (WHERE hc.email IS NULL OR hc.email = ''),
    COUNT(*) FILTER (WHERE hc.email_uncertain IS TRUE)
  INTO v_skipped_no_addr, v_skipped_unsure
  FROM public.hiring_candidates hc
  WHERE hc.agency_id = p_agency_id
    AND hc.status = 'declined'
    AND hc.is_test_candidate IS NOT TRUE
    AND hc.status_updated_at >= v_cutover
    AND (hc.decline_reason IS NULL
         OR hc.decline_reason NOT IN ('calibration_only', 'bounced_undeliverable'))
    AND NOT EXISTS (SELECT 1 FROM public.candidate_decline_notices n WHERE n.candidate_id = hc.id);

  FOR v_cand IN
    SELECT hc.id, hc.first_name, hc.email, hc.position, hc.decline_reason
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.status = 'declined'
      AND hc.is_test_candidate IS NOT TRUE
      AND hc.email IS NOT NULL
      AND hc.email <> ''
      -- An address we are not confident in goes to a stranger if it is wrong.
      AND hc.email_uncertain IS NOT TRUE
      AND hc.status_updated_at IS NOT NULL
      AND hc.status_updated_at >= v_cutover
      -- calibration_only: Peter's explicit carve-out — paper-only records, never
      --   real applicants, nobody to write to.
      -- bounced_undeliverable: the address already hard-bounced. Mailing it again
      --   cannot reach anyone and feeds a second bounce into the bounce detector.
      AND (hc.decline_reason IS NULL
           OR hc.decline_reason NOT IN ('calibration_only', 'bounced_undeliverable'))
      AND NOT EXISTS (
        SELECT 1 FROM public.candidate_decline_notices n WHERE n.candidate_id = hc.id
      )
      -- The candidate withdrew first. candidate_email_response_apply() stamps
      -- these 'active_applicant', which is indistinguishable from a real decline
      -- on the column alone. Telling someone we are passing on them after they
      -- already told us they are out reads badly and is simply not true.
      AND NOT EXISTS (
        SELECT 1 FROM public.candidate_email_responses r
        WHERE r.hiring_candidate_id = hc.id
          AND r.response_type = 'declining'
      )
    ORDER BY hc.status_updated_at
    LIMIT v_max_per_run
  LOOP
    BEGIN
      v_role_phrase := CASE
        WHEN v_cand.position IS NOT NULL AND v_cand.position <> ''
          THEN 'the <strong>' || v_cand.position || '</strong> role'
        ELSE 'a role'
      END;

      v_subject := 'Update on your application — Peter Story State Farm';

      v_html :=
        '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
        '<p>Thank you for applying for ' || v_role_phrase || ' at Peter Story State Farm, ' ||
          'and for the time you put into the process. I have decided to move forward with ' ||
          'other candidates for this position.</p>' ||
        '<p>That is a decision about fit for one particular seat at one particular moment, ' ||
          'and nothing more. I know how much work a job search takes, and I do not take it ' ||
          'lightly that you spent some of that effort here.</p>' ||
        '<p>The care you put into how you present yourself does show, and it will keep ' ||
          'showing. Our openings change through the year — if something opens that fits ' ||
          'you, please apply again. I would be glad to take another look.</p>' ||
        '<p>I wish you real success in whatever comes next.</p>' ||
        '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';

      v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

      INSERT INTO public.candidate_decline_notices
        (agency_id, candidate_id, decline_reason, subject, sent_at, pg_net_request_id)
      VALUES
        (p_agency_id, v_cand.id, v_cand.decline_reason, v_subject, NOW(), v_pg_net_id);

      v_sent := v_sent + 1;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object(
        'candidate_id', v_cand.id,
        'error', SQLERRM
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'errors', v_errors,
    'error_details', v_error_details,
    'skipped_no_address', v_skipped_no_addr,
    'skipped_email_uncertain', v_skipped_unsure,
    'ran_at', NOW(),
    'records_processed', v_sent,
    'output_summary', v_sent || ' decline notice(s) sent, ' || v_errors || ' error(s)' ||
      CASE WHEN v_skipped_no_addr + v_skipped_unsure > 0
        THEN ' (skipped: ' || v_skipped_no_addr || ' no address, ' ||
             v_skipped_unsure || ' address unconfirmed)'
        ELSE '' END
  );
END;
$function$;

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   composio_action, internal_handler, is_active, timezone)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Send Candidate Decline Notices',
  'Sweeps declined candidates and sends each one a warm decline email. Skips calibration-only records, dead addresses, and candidates who withdrew first. One notice per candidate, ever.',
  'cron',
  '*/15 * * * *',
  'INTERNAL',
  'send_candidate_decline_notices',
  true,
  'America/Chicago'
);
