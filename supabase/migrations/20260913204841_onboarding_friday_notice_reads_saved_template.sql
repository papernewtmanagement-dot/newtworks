-- Pull the wording from the saved hiring template so editing it there changes
-- what gets posted, instead of the text living in two places.
CREATE OR REPLACE FUNCTION public.onboarding_friday_notice(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  p_recipe_id uuid DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r        record;
  v_sent   int := 0;
  v_txt    text;
  v_body   text;
BEGIN
  SELECT body_html INTO v_body
  FROM public.hiring_email_templates
  WHERE agency_id = p_agency_id AND template_key = 'start_friday_text';

  IF v_body IS NULL THEN
    v_body := 'Hi {{first_name}} — looking forward to Monday. Please arrive by 8:30 with your driver license and Social Security card.';
  END IF;

  FOR r IN
    SELECT p.id, p.start_date,
           COALESCE(
             NULLIF(TRIM(COALESCE(t.nickname, t.first_name) || ' ' || COALESCE(t.last_name,'')), ''),
             NULLIF(TRIM(COALESCE(c.first_name,'') || ' ' || COALESCE(c.last_name,'')), ''),
             c.candidate_name, 'the new hire') AS full_name,
           COALESCE(t.nickname, t.first_name, c.first_name, 'there') AS first_name,
           COALESCE(t.phone_personal, c.phone) AS phone
    FROM public.team_onboarding_plans p
    LEFT JOIN public.team t ON t.id = p.team_member_id
    LEFT JOIN public.hiring_candidates c ON c.id = p.candidate_id
    WHERE p.agency_id = p_agency_id
      AND p.status = 'active'
      AND p.friday_notice_sent_at IS NULL
      AND p.start_date IS NOT NULL
      AND p.start_date > CURRENT_DATE
      AND p.start_date <= CURRENT_DATE + 4
  LOOP
    v_txt :=
      '<b>' || r.full_name || ' starts ' || to_char(r.start_date, 'Dy Mon FMDD') || '</b>' || E'\n\n' ||
      'Their number: ' || COALESCE(r.phone, 'not on file') || E'\n\n' ||
      'Text to send:' || E'\n' ||
      replace(v_body, '{{first_name}}', r.first_name) || E'\n\n' ||
      'Also: print the Day 1 packet — Login Packet plus the New Hire Documents ' ||
      '(W-4, I-9, State Farm Annual Certification, Non-Compete, Payroll and Bio).';

    PERFORM public.telegram_send('admin', v_txt, p_agency_id, 'HTML');

    UPDATE public.team_onboarding_plans
    SET friday_notice_sent_at = now() WHERE id = r.id;

    v_sent := v_sent + 1;
  END LOOP;

  RETURN jsonb_build_object('sent', v_sent);
END;
$function$;