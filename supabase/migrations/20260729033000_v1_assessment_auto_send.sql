-- v1 assessment auto-send: table + composio helper + scan-and-send fn + recipe row.
-- OQ 26e829ec (auto-send at hiring pipeline stage). Path chosen: recipe scan
-- of hiring_candidates every 15 min. Inert until email capture works at intake.

-- 1. Invitations table (one row per send; attempt 1 in this OQ, attempts 2/3 in OQ #4).
CREATE TABLE IF NOT EXISTS public.assessment_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  candidate_id uuid NOT NULL REFERENCES public.hiring_candidates(id) ON DELETE CASCADE,
  attempt_number int NOT NULL DEFAULT 1 CHECK (attempt_number BETWEEN 1 AND 3),
  sent_at timestamptz NOT NULL DEFAULT NOW(),
  pg_net_request_id bigint,
  subject text,
  outcome text NOT NULL DEFAULT 'sent' CHECK (outcome IN ('sent','completed','declined','no_response','send_failed')),
  next_attempt_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_assessment_invitations_candidate
  ON public.assessment_invitations(candidate_id);
CREATE INDEX IF NOT EXISTS idx_assessment_invitations_agency_outcome
  ON public.assessment_invitations(agency_id, outcome);

ALTER TABLE public.assessment_invitations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read_assessment_invitations ON public.assessment_invitations;
CREATE POLICY anon_read_assessment_invitations
  ON public.assessment_invitations
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS authenticated_update_assessment_invitations ON public.assessment_invitations;
CREATE POLICY authenticated_update_assessment_invitations
  ON public.assessment_invitations
  FOR UPDATE
  TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- 2. General Composio email helper. Duplicates the time_off_send_email body
-- verbatim under a name that reflects what it actually does. time_off_send_email
-- stays as-is so its existing caller (time_off_notification_dispatch) is untouched.
CREATE OR REPLACE FUNCTION public.composio_send_email(
  p_agency_id uuid,
  p_to text,
  p_subject text,
  p_html_body text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net'
AS $function$
DECLARE
  v_api_key text;
  v_user_id text;
  v_connected_account_id text;
  v_request_id bigint;
BEGIN
  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';

  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';

  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_gmail_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RAISE EXCEPTION 'Composio Gmail config missing (api_key=%, user_id=%, connected_account_id=%)',
      v_api_key IS NOT NULL, v_user_id IS NOT NULL, v_connected_account_id IS NOT NULL;
  END IF;

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL',
    headers := jsonb_build_object(
      'x-api-key', v_api_key,
      'Content-Type', 'application/json'
    ),
    body    := jsonb_build_object(
      'user_id', v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments', jsonb_build_object(
        'recipient_email', p_to,
        'subject', p_subject,
        'body', p_html_body,
        'is_html', true
      )
    )
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$function$;

-- 3. Scan-and-send handler. Rate-capped, idempotent per candidate via existence
-- check on assessment_invitations. Skips candidates already assessed (v1 alert exists).
CREATE OR REPLACE FUNCTION public.send_v1_assessment_invitations(
  p_agency_id uuid,
  p_recipe_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sent int := 0;
  v_errors int := 0;
  v_max_per_run int := 10;
  v_cand RECORD;
  v_link_path text;
  v_full_link text;
  v_app_url text := 'https://newtworks.vercel.app';
  v_subject text;
  v_html text;
  v_pg_net_id bigint;
  v_position_display text;
  v_sent_ids uuid[] := ARRAY[]::uuid[];
  v_error_details jsonb := '[]'::jsonb;
BEGIN
  FOR v_cand IN
    SELECT hc.id, hc.first_name, hc.last_name, hc.email, hc.position
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.status = 'applied'
      AND hc.email IS NOT NULL
      AND hc.email <> ''
      AND NOT EXISTS (
        SELECT 1 FROM public.assessment_invitations ai
        WHERE ai.candidate_id = hc.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.alerts a
        WHERE a.agency_id = p_agency_id
          AND a.alert_type = 'v1_assessment_complete'
          AND a.related_id = hc.id
      )
    ORDER BY hc.applied_at NULLS LAST, hc.created_at
    LIMIT v_max_per_run
  LOOP
    BEGIN
      v_link_path := public.mint_v1_assessment_link(v_cand.id);
      v_full_link := v_app_url || v_link_path;
      v_position_display := COALESCE(NULLIF(v_cand.position, ''), 'the role');

      v_subject := 'Assessment for ' || v_position_display || ' at Peter Story State Farm';

      v_html :=
        '<p>Hi ' || COALESCE(v_cand.first_name, 'there') || ',</p>' ||
        '<p>Thanks for applying for the <strong>' || v_position_display ||
          '</strong> role at Peter Story State Farm.</p>' ||
        '<p>Before we schedule any live conversation, please work through this short ' ||
          'assessment. It takes about 30 minutes and covers personality, working style, ' ||
          'and a bit of aptitude. Nothing to study for &mdash; just answer honestly.</p>' ||
        '<p><a href="' || v_full_link || '" style="display:inline-block;padding:12px 24px;' ||
          'background:#2563eb;color:#ffffff;text-decoration:none;border-radius:6px;' ||
          'font-weight:600;">Start the assessment</a></p>' ||
        '<p style="color:#64748b;font-size:13px;">If the button does not work, paste this ' ||
          'link into your browser:<br><a href="' || v_full_link || '">' || v_full_link || '</a></p>' ||
        '<p>Once you are done, I will review your results along with a short set of written ' ||
          'questions I will send next. If we are a fit, we will schedule a video call.</p>' ||
        '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';

      v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

      INSERT INTO public.assessment_invitations
        (agency_id, candidate_id, attempt_number, sent_at, pg_net_request_id, subject, outcome)
      VALUES
        (p_agency_id, v_cand.id, 1, NOW(), v_pg_net_id, v_subject, 'sent');

      v_sent := v_sent + 1;
      v_sent_ids := array_append(v_sent_ids, v_cand.id);
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
    'sent_candidate_ids', to_jsonb(v_sent_ids),
    'ran_at', NOW()
  );
END;
$function$;

-- 4. Automation recipe row. Interval-based (every 15 min UTC) — timezone-independent.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description,
  trigger_type, cron_expression, timezone,
  internal_handler, is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'Send v1 Assessment Invitations',
  'Scan hiring_candidates for status=applied rows with email, no prior invitation, and no completed assessment. Sends the Newtworks v1 assessment link via Composio Gmail. Rate cap: 10 per run. Interval: every 15 min UTC.',
  'cron',
  '*/15 * * * *',
  'UTC',
  'send_v1_assessment_invitations',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND recipe_name = 'Send v1 Assessment Invitations'
);
