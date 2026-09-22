-- Peter 2026-09-21: code flag email goes out as ONE message to the whole team,
-- not a separate copy per person. composio_send_email gains an optional list of
-- extra To recipients (Gmail extra_recipients). Existing 4-argument callers are
-- unchanged. Dropped and recreated so there is still exactly one sender function.

DROP FUNCTION IF EXISTS public.composio_send_email(uuid, text, text, text);

CREATE OR REPLACE FUNCTION public.composio_send_email(
  p_agency_id uuid, p_to text, p_subject text, p_html_body text,
  p_extra_to text[] DEFAULT NULL)
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
  v_args jsonb;
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

  v_args := jsonb_build_object(
    'recipient_email', p_to,
    'subject', p_subject,
    'body', p_html_body,
    'is_html', true
  );
  IF p_extra_to IS NOT NULL AND cardinality(p_extra_to) > 0 THEN
    v_args := v_args || jsonb_build_object('extra_recipients', to_jsonb(p_extra_to));
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
      'arguments', v_args
    )
  ) INTO v_request_id;

  RETURN v_request_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.composio_send_email(uuid, text, text, text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.composio_send_email(uuid, text, text, text, text[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.code_flag_notify_team(p_flag_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  f record;
  v_who text;
  v_label text;
  v_color text;
  v_subject text;
  v_body text;
  v_note text;
  v_fix text;
  v_to text[];
BEGIN
  SELECT cf.*, t.first_name, t.last_name, t.nickname
    INTO f
  FROM public.code_flags cf
  JOIN public.team t ON t.id = cf.team_member_id
  WHERE cf.id = p_flag_id;
  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT array_agg(e ORDER BY e) INTO v_to FROM (
    SELECT DISTINCT lower(btrim(t.email_sf)) AS e
    FROM public.team t
    WHERE t.agency_id = f.agency_id
      AND t.is_active = true
      AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user, false) = false
      AND t.category = 'agency'
      AND NULLIF(btrim(t.email_sf), '') IS NOT NULL
  ) s;
  IF v_to IS NULL OR cardinality(v_to) = 0 THEN RETURN 0; END IF;

  v_who   := btrim(COALESCE(NULLIF(btrim(f.nickname), ''), f.first_name) || ' ' || COALESCE(f.last_name, ''));
  v_label := CASE f.severity WHEN 'red' THEN 'Code Red' ELSE 'Code Yellow' END;
  v_color := CASE f.severity WHEN 'red' THEN '#c0392b' ELSE '#b7791f' END;

  v_note := replace(replace(replace(COALESCE(f.note, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_note := replace(v_note, E'\n', '<br>');
  v_fix  := replace(replace(replace(COALESCE(NULLIF(btrim(f.correction), ''), ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  v_fix  := replace(v_fix, E'\n', '<br>');

  v_subject := v_label || ' logged by ' || v_who;
  v_body :=
    '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#222">'
    || '<p style="margin:0 0 12px"><strong style="color:' || v_color || '">' || v_label || '</strong> logged by '
    || v_who || ' for ' || to_char(f.flag_date, 'FMDay, FMMonth FMDD') || '.</p>'
    || '<p style="margin:0 0 4px"><strong>What happened</strong></p>'
    || '<p style="margin:0 0 12px">' || v_note || '</p>'
    || CASE WHEN v_fix <> '' THEN
         '<p style="margin:0 0 4px"><strong>How it was fixed</strong></p><p style="margin:0">' || v_fix || '</p>'
       ELSE '' END
    || '</div>';

  PERFORM public.composio_send_email(f.agency_id, v_to[1], v_subject, v_body, v_to[2:]);
  RETURN cardinality(v_to);
END;
$function$;

REVOKE ALL ON FUNCTION public.code_flag_notify_team(uuid) FROM PUBLIC, anon, authenticated;

