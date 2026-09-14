ALTER TABLE public.team_onboarding_plans
  ADD COLUMN IF NOT EXISTS friday_notice_sent_at timestamptz;

-- Friday before a start date: drop the text to send, their number and the
-- packet reminder into the Paper Newt Management group.
CREATE OR REPLACE FUNCTION public.onboarding_friday_notice(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  p_recipe_id uuid DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r      record;
  v_sent int := 0;
  v_txt  text;
BEGIN
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
      '"Hi ' || r.first_name || ' — really looking forward to kicking things off with you Monday. ' ||
      'Plan to be here by 8:30. Bring your driver license and Social Security card and that is all you need. ' ||
      'Text me here if anything comes up over the weekend."' || E'\n\n' ||
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

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   internal_handler, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Onboarding — Friday before start notice',
       'Friday morning: posts the welcome text, the new hire phone number and the Day 1 packet reminder to the Paper Newt Management group for anyone starting in the next few days.',
       'cron', '0 9 * * 5', 'onboarding_friday_notice', true, 'America/Chicago'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND internal_handler = 'onboarding_friday_notice'
);