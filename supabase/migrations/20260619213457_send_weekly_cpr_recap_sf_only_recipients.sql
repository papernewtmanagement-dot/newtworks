-- Per Peter 2026-06-19: send to SF emails only, including Peter's SF email.
-- Drops the 5 personal emails and the Cc to storypeterj@gmail.com.
-- Total recipients: 6 (5 team SF + Peter SF).
CREATE OR REPLACE FUNCTION public.send_weekly_cpr_recap(
  p_agency_id uuid,
  p_week_ending_date date
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_report                  record;
  v_html                    text;
  v_api_key                 text;
  v_user_id                 text;
  v_connected_account_id    text;
  v_subject                 text;
  v_week_start              date := p_week_ending_date - 6;
  v_start_mon               text;
  v_end_mon                 text;
  v_start_day               text;
  v_end_day                 text;
  v_subject_dates           text;
  v_request_id              bigint;
  v_recipients_to           text[];
  v_primary_to              text;
  v_extra_to                text[];
BEGIN
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'No weekly_cpr_reports row exists for this week. Save the CPR before sending.');
  END IF;

  IF v_report.sent_to_team_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already sent at ' || v_report.sent_to_team_at::text || '. Clear sent_to_team_at to re-arm.');
  END IF;

  IF v_report.opener_text IS NULL OR btrim(v_report.opener_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Opener text is empty. Write the opener before sending.');
  END IF;

  IF v_report.looking_next_week_text IS NULL OR btrim(v_report.looking_next_week_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', '"Looking at next week" text is empty. Write it before sending.');
  END IF;

  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_gmail_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Composio Gmail config missing in settings table');
  END IF;

  -- Per Peter 2026-06-19: SF emails only, including Peter's. No personal emails. No Cc.
  v_recipients_to := ARRAY[
    'john.kostov.vaelna@statefarm.com',
    'thomas.lynch.vaisz9@statefarm.com',
    'cassie.alves.vakfno@statefarm.com',
    'jason.fuller.vakhkl@statefarm.com',
    'stephanie.rogers.vakhkm@statefarm.com',
    'peter.story.yrru@statefarm.com'
  ];

  v_primary_to := v_recipients_to[1];
  v_extra_to   := v_recipients_to[2:];

  v_start_mon := upper(to_char(v_week_start,       'Mon'));
  v_end_mon   := upper(to_char(p_week_ending_date, 'Mon'));
  v_start_day := to_char(v_week_start,       'FMDD');
  v_end_day   := to_char(p_week_ending_date, 'FMDD');
  IF v_start_mon = v_end_mon THEN
    v_subject_dates := v_start_mon || ' ' || v_start_day || '–' || v_end_day;
  ELSE
    v_subject_dates := v_start_mon || ' ' || v_start_day || ' – ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_subject := '📊 CPR RECAP — WEEK OF ' || v_subject_dates;

  v_html := public.compose_weekly_cpr_html(p_agency_id, p_week_ending_date);

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
        'recipient_email', v_primary_to,
        'extra_recipients', to_jsonb(v_extra_to),
        'subject', v_subject,
        'body', v_html,
        'is_html', true
      )
    )
  ) INTO v_request_id;

  UPDATE public.weekly_cpr_reports
     SET sent_to_team_at = now()
   WHERE id = v_report.id;

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_request_id,
    'subject', v_subject,
    'recipients_to_count', array_length(v_recipients_to, 1),
    'sent_to_team_at', now()
  );
END;
$func$;

-- Also update the locked operational_rule DELIVERY recipients
UPDATE public.persistent_memory
SET content = REPLACE(
  content,
  E'- To: 5 active team members on BOTH SF and personal emails (10 recipients total) — locked per Peter 2026-06-18:\n    SF:        john.kostov.vaelna@statefarm.com, thomas.lynch.vaisz9@statefarm.com,\n               cassie.alves.vakfno@statefarm.com, jason.fuller.vakhkl@statefarm.com,\n               stephanie.rogers.vakhkm@statefarm.com\n    Personal:  john.kostov@gmail.com, tlynch1874@gmail.com,\n               angracassie13@gmail.com, thejdfuller@gmail.com,\n               slrogers729@gmail.com\n- Cc: storypeterj@gmail.com\n- From: paper.newt.management@gmail.com',
  E'- To: 5 active team members on SF emails + Peter on his SF email (6 recipients total) — locked per Peter 2026-06-19:\n    john.kostov.vaelna@statefarm.com, thomas.lynch.vaisz9@statefarm.com,\n    cassie.alves.vakfno@statefarm.com, jason.fuller.vakhkl@statefarm.com,\n    stephanie.rogers.vakhkm@statefarm.com, peter.story.yrru@statefarm.com\n- Cc: none\n- From: paper.newt.management@gmail.com\n- Personal-email channel and Cc to storypeterj@gmail.com REMOVED 2026-06-19. Prior locked recipient list (10 dual-inbox + Cc) is superseded.'
),
  updated_at = NOW()
WHERE id = 'dc5e694a-97a2-426c-8eb2-fbbcb6b1e5b1';
