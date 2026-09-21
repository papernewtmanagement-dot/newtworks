-- Peter 2026-09-21: every Code Red or Code Yellow logged on the site emails the
-- whole agency team at their State Farm addresses.
-- Recipients: active agency-side team members with a State Farm email on file.
-- One email per person through composio_send_email (the one Gmail sender).
-- A failed send never blocks the flag from saving; it writes an alert instead.

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
  r record;
  v_sent integer := 0;
BEGIN
  SELECT cf.*, t.first_name, t.last_name, t.nickname
    INTO f
  FROM public.code_flags cf
  JOIN public.team t ON t.id = cf.team_member_id
  WHERE cf.id = p_flag_id;
  IF NOT FOUND THEN RETURN 0; END IF;

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

  FOR r IN
    SELECT DISTINCT lower(btrim(t.email_sf)) AS email
    FROM public.team t
    WHERE t.agency_id = f.agency_id
      AND t.is_active = true
      AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user, false) = false
      AND t.category = 'agency'
      AND NULLIF(btrim(t.email_sf), '') IS NOT NULL
  LOOP
    PERFORM public.composio_send_email(f.agency_id, r.email, v_subject, v_body);
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trg_code_flag_notify_team()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  BEGIN
    PERFORM public.code_flag_notify_team(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, related_id)
    VALUES (NEW.agency_id, 'code_flag_email_failed', 'warning',
            'Code flag email did not send',
            'The team email for a ' || NEW.severity || ' code flag failed: ' || SQLERRM,
            'code_flags', NEW.id);
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_code_flag_notify_team ON public.code_flags;
CREATE TRIGGER trg_code_flag_notify_team
AFTER INSERT ON public.code_flags
FOR EACH ROW EXECUTE FUNCTION public.trg_code_flag_notify_team();

REVOKE ALL ON FUNCTION public.code_flag_notify_team(uuid) FROM PUBLIC, anon, authenticated;

