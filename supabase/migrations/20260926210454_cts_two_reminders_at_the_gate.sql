-- CTS reminders (Peter decision 2026-09-26, "1B"): anyone waiting at the CTS
-- gate gets two reminders - one a day after the sales profile link, one a day
-- after that - then nothing more. Same rhythm as the assessment reminders.
-- Only status 'assessed' (that is where the gate holds people). The wording
-- lives in hiring_email_templates (key cts_reminder) so Peter can edit it under
-- Team > Growth > Email Templates like every other hiring letter.

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS cts_reminder_1_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS cts_reminder_2_sent_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.cts_reminder_1_sent_at IS
  'First CTS reminder, sent a day after cts_invite_sent_at by send_cts_sales_profile_invites. Status assessed only.';
COMMENT ON COLUMN public.hiring_candidates.cts_reminder_2_sent_at IS
  'Second and last CTS reminder, a day after the first.';

INSERT INTO public.hiring_email_templates
  (agency_id, template_key, title, stage, sort_order, subject, body_html, tokens, description, sent_when)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'cts_reminder', 'Sales profile reminder', 'Sales profile', 25,
  'Reminder: sales profile for {{position}} at Peter Story State Farm',
  '<p>Hi {{first_name}},</p>
<p>Just following up on the sales profile for {{role_phrase}} at Peter Story State Farm. It is the last step before I send you times to pick from for the interview.</p>
<p>It takes about 25 minutes and there is nothing to prepare. Your link is still active:</p>
<p><a href="{{cts_link}}" style="display:inline-block;padding:12px 24px;background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:600;">Start the sales profile</a></p>
<p style="color:#64748b;font-size:13px;">The link will have you register first, then it starts. If the button does not work, paste this link into your browser:<br><a href="{{cts_link}}">{{cts_link}}</a></p>
<p>If you have decided not to pursue this role, just reply to this email and let me know so I can update our records.</p>
<p>&mdash; Peter Story<br>Peter Story State Farm</p>',
  ARRAY['first_name','position','role_phrase','cts_link'],
  'Nudge for an unfinished sales profile (CTS). Sends twice, a day apart, then stops.',
  'Automatically, a day after the sales profile link, up to two reminders.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.hiring_email_templates
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'cts_reminder');

CREATE OR REPLACE FUNCTION public.send_cts_sales_profile_invites(p_agency_id uuid, p_recipe_id uuid, p_backfill boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_live_since    timestamptz;
  v_max_per_run   int := 10;
  v_sent          int := 0;
  v_reminded      int := 0;
  v_errors        int := 0;
  v_error_details jsonb := '[]'::jsonb;
  v_sent_ids      uuid[] := ARRAY[]::uuid[];
  v_reminded_ids  uuid[] := ARRAY[]::uuid[];
  v_cand          RECORD;
  v_res           jsonb;
  v_url           text;
  v_subject       text;
  v_html          text;
  v_pg_net_id     bigint;
BEGIN
  IF p_backfill THEN
    v_live_since := '-infinity'::timestamptz;
  ELSE
    SELECT created_at INTO v_live_since
    FROM public.automation_recipes WHERE id = p_recipe_id;
    IF v_live_since IS NULL THEN v_live_since := NOW(); END IF;
  END IF;

  -- Step 1: the CTS link, once, an hour after the assessment is done.
  -- send_cts_invite_to_candidate owns that letter; unchanged.
  FOR v_cand IN
    SELECT hc.id
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.is_test_candidate IS NOT TRUE
      AND hc.cts_invite_sent_at IS NULL
      AND hc.assessment_completed_at IS NOT NULL
      AND hc.assessment_completed_at >= v_live_since
      AND hc.assessment_completed_at <= NOW() - INTERVAL '1 hour'
      AND hc.status IN ('assessed', 'interview', 'meet_and_greet', 'offer', 'reference_check')
      AND hc.decision_at IS NULL
      AND hc.assessment_exit_gate IS NULL
      AND hc.email IS NOT NULL
      AND hc.email <> ''
    ORDER BY hc.assessment_completed_at
    LIMIT v_max_per_run
  LOOP
    BEGIN
      v_res := public.send_cts_invite_to_candidate(p_agency_id, v_cand.id);
      IF v_res->>'action' = 'sent' THEN
        v_sent := v_sent + 1;
        v_sent_ids := array_append(v_sent_ids, v_cand.id);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object(
        'candidate_id', v_cand.id, 'error', SQLERRM);
    END;
  END LOOP;

  -- Step 2 (2026-09-26): two reminders for anyone still waiting at the gate.
  -- Reminder 1 a day after the link, reminder 2 a day after reminder 1, then
  -- stop. Status 'assessed' only - people past the gate (interview onward)
  -- were sent the link under the old order and are not chased.
  SELECT setting_value INTO v_url
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cts_sales_profile_register_url';

  IF v_url IS NOT NULL AND btrim(v_url) <> '' THEN
    FOR v_cand IN
      SELECT hc.id, hc.first_name, hc.email, hc.position,
             CASE WHEN hc.cts_reminder_1_sent_at IS NULL THEN 1 ELSE 2 END AS n
      FROM public.hiring_candidates hc
      WHERE hc.agency_id = p_agency_id
        AND hc.is_test_candidate IS NOT TRUE
        AND hc.status = 'assessed'
        AND hc.decision_at IS NULL
        AND hc.assessment_exit_gate IS NULL
        AND hc.cts_completed_at IS NULL
        AND hc.cts_invite_sent_at IS NOT NULL
        AND hc.cts_reminder_2_sent_at IS NULL
        AND hc.email IS NOT NULL
        AND hc.email <> ''
        AND (
          (hc.cts_reminder_1_sent_at IS NULL AND hc.cts_invite_sent_at <= NOW() - INTERVAL '1 day')
          OR (hc.cts_reminder_1_sent_at IS NOT NULL AND hc.cts_reminder_1_sent_at <= NOW() - INTERVAL '1 day')
        )
      ORDER BY hc.cts_invite_sent_at
      LIMIT GREATEST(v_max_per_run - v_sent, 0)
    LOOP
      BEGIN
        SELECT r.subject, r.body_html INTO v_subject, v_html
        FROM public.render_hiring_email(p_agency_id, 'cts_reminder', jsonb_build_object(
          'first_name',  COALESCE(NULLIF(v_cand.first_name, ''), 'there'),
          'position',    COALESCE(NULLIF(v_cand.position, ''), 'the role'),
          'role_phrase', CASE WHEN NULLIF(v_cand.position, '') IS NOT NULL
                              THEN 'the <strong>' || v_cand.position || '</strong> role'
                              ELSE 'this role' END,
          'cts_link',    v_url
        )) r;

        v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

        IF v_cand.n = 1 THEN
          UPDATE public.hiring_candidates SET cts_reminder_1_sent_at = NOW() WHERE id = v_cand.id;
        ELSE
          UPDATE public.hiring_candidates SET cts_reminder_2_sent_at = NOW() WHERE id = v_cand.id;
        END IF;

        v_reminded := v_reminded + 1;
        v_reminded_ids := array_append(v_reminded_ids, v_cand.id);
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors + 1;
        v_error_details := v_error_details || jsonb_build_object(
          'stage', 'reminder', 'candidate_id', v_cand.id, 'error', SQLERRM);
      END;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'reminders_sent', v_reminded,
    'errors', v_errors,
    'error_details', v_error_details,
    'sent_candidate_ids', to_jsonb(v_sent_ids),
    'reminded_candidate_ids', to_jsonb(v_reminded_ids),
    'backfill', p_backfill,
    'ran_at', NOW(),
    'records_processed', v_sent + v_reminded,
    'output_summary', v_sent || ' CTS invite(s) sent, ' || v_reminded || ' reminder(s) sent, ' || v_errors || ' error(s)');
END;
$function$;
