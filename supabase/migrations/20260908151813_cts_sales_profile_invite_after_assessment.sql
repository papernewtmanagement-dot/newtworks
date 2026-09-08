-- =========================================================================
-- CTS Sales Profile invite after the Newtworks assessment (2026-09-08)
-- =========================================================================
-- Peter directive 2026-09-08: "When someone takes our assessment, wait an
-- hour and send them the CTS assessment."
--
-- Flow today (unchanged): v1-assessment finalize stamps
-- hiring_candidates.assessment_completed_at and flips status to 'assessed';
-- trg_dispatch_assessed_candidate then runs the verdict at once. Decline ->
-- status 'declined' + decline letter. Consider/pass -> status 'interview' +
-- interview booking email, sent within seconds of finishing.
--
-- This adds one hourly recipe (rides the :59 runner tick, no new cron job)
-- that emails the CTS registration link to every candidate who finished the
-- assessment at least one hour ago and moved on past it. Real delay is one
-- to two hours: the tick lands at :59, so a 2:05 finish is picked up at 3:59.
--
-- Why an hour and not right away: the interview booking email already lands
-- the second they finish. Spacing the two asks keeps one from burying the
-- other, and gives a 30-minute-assessment taker a break before a 25-minute
-- questionnaire (later items get faster, flatter answers when a sitting runs
-- long: Galesic & Bosnjak 2009, Public Opinion Quarterly). Why not next day:
-- slow next steps read as low interest and drive withdrawal, strongest
-- candidates first (Rynes, Bretz & Gerhart 1991, Personnel Psychology;
-- Boswell, Roehling, LePine & Moynihan 2003, Human Resource Management).
--
-- Who is excluded: auto-declined at the verdict, withdrawn, former team,
-- hired, test rows, anyone with a decision on file, and anyone who finished
-- before this recipe existed (no backfill of the 17 already in 'interview').
--
-- The link lives in settings (cts_sales_profile_register_url) so it can be
-- changed without a migration and so a second agency can carry its own.
-- Blank setting = nothing sends.
-- =========================================================================

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS cts_invite_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS cts_invite_pg_net_id bigint;

COMMENT ON COLUMN public.hiring_candidates.cts_invite_sent_at IS
  'When the CTS Sales Profile registration link was emailed to the candidate by send_cts_sales_profile_invites. NULL = not sent yet.';

INSERT INTO public.settings
  (agency_id, setting_key, setting_value, setting_type, description, updated_by, updated_at, created_at)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'cts_sales_profile_register_url',
   'https://app.ctssalesprofile.com/register?link_id=R-4668-559794',
   'string',
   'CTS Sales Profile candidate registration link. send_cts_sales_profile_invites emails it one to two hours after a candidate finishes the Newtworks assessment and is not declined. Blank = no sends.',
   'claude', NOW(), NOW())
ON CONFLICT (agency_id, setting_key) DO UPDATE
  SET setting_value = EXCLUDED.setting_value,
      description   = EXCLUDED.description,
      updated_at    = NOW();

CREATE OR REPLACE FUNCTION public.send_cts_sales_profile_invites(p_agency_id uuid, p_recipe_id uuid)
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
DECLARE
  v_url            text;
  v_live_since     timestamptz;
  v_max_per_run    int := 10;
  v_sent           int := 0;
  v_errors         int := 0;
  v_error_details  jsonb := '[]'::jsonb;
  v_sent_ids       uuid[] := ARRAY[]::uuid[];
  v_cand           RECORD;
  v_position       text;
  v_subject        text;
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
  -- not backfilled. Read from the recipe itself so there is no magic date here.
  SELECT created_at INTO v_live_since
  FROM public.automation_recipes WHERE id = p_recipe_id;
  IF v_live_since IS NULL THEN v_live_since := NOW(); END IF;

  FOR v_cand IN
    SELECT hc.id, hc.first_name, hc.email, hc.position
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
      v_position := COALESCE(NULLIF(v_cand.position, ''), 'the role');
      v_subject  := 'Next step: sales profile assessment for ' || v_position ||
                    ' at Peter Story State Farm';

      v_html :=
        '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
        '<p>Thanks for finishing the assessment. I appreciate the time you put in.</p>' ||
        '<p>There is one more step before we meet. It is a short sales profile called the CTS. ' ||
          'It takes about 25 minutes and there is nothing to prepare. Answer the same way you did ' ||
          'on the first one, honestly and without overthinking it.</p>' ||
        '<p><a href="' || v_url || '" style="display:inline-block;padding:12px 24px;' ||
          'background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;' ||
          'font-weight:600;">Start the sales profile</a></p>' ||
        '<p style="color:#64748b;font-size:13px;">The link will have you register first, then it starts. ' ||
          'If the button does not work, paste this link into your browser:<br>' ||
          '<a href="' || v_url || '">' || v_url || '</a></p>' ||
        '<p>Please finish it before your interview so we can talk through both sets of results together.</p>' ||
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
    'ran_at', NOW(),
    'records_processed', v_sent,
    'output_summary', v_sent || ' CTS invite(s) sent, ' || v_errors || ' error(s)');
END;
$function$;

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone,
   composio_action, internal_handler, is_active)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'Send CTS Sales Profile Invites',
  'Hourly on the :59 tick. Emails the CTS Sales Profile registration link (settings.cts_sales_profile_register_url) to every candidate who finished the Newtworks assessment at least one hour ago and was advanced past it (interview or later, no decision on file). Real delay one to two hours. One send per candidate, stamped on hiring_candidates.cts_invite_sent_at. No backfill of candidates who finished before this recipe was created.',
  'cron', '59 * * * *', 'UTC',
  'INTERNAL', 'send_cts_sales_profile_invites', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND recipe_name = 'Send CTS Sales Profile Invites');
