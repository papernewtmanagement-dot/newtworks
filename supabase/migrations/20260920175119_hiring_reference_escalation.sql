-- Item 4. What happens when references do not answer.
--
--   three attempts on a number          -> that contact is unreachable
--   every contact resolved, not enough  -> email the candidate, listing every
--   good ones yet                          reference we could not reach, and
--                                          start a three-day clock
--   three days later                    -> those contacts reopen for three
--                                          more attempts, caller is told
--   that round fails too                -> one final email to the candidate
--   still short of the minimum          -> pause the whole reference check
--
-- Attempts are cumulative, so a round is exhausted at attempt_count >= 3 *
-- round. Nothing here decides whether a reference is good: that is
-- hiring_reference_progress, which is the only counter of positives.

CREATE OR REPLACE FUNCTION public.hiring_reference_escalation(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_recipe_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  c            record;
  k            record;
  em           record;
  v_prog       jsonb;
  v_pending    int;
  v_stuck      int;
  v_list_html  text;
  v_list_tg    text;
  v_caller     text;
  v_base       text;
  v_link       text;
  v_exhausted  int := 0;
  v_helped     int := 0;
  v_reopened   int := 0;
  v_final      int := 0;
  v_paused     int := 0;
BEGIN
  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');
  v_link := v_base || '/references';

  FOR c IN
    SELECT hc.id, hc.agency_id, hc.first_name, hc.email,
           COALESCE(NULLIF(TRIM(COALESCE(hc.first_name,'') || ' ' || COALESCE(hc.last_name,'')), ''),
                    hc.candidate_name, 'the candidate') AS name,
           hc.reference_help_email_sent_at, hc.reference_round2_opens_at,
           hc.reference_final_email_sent_at, hc.reference_paused_at
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.reference_paused_at IS NULL
      AND EXISTS (SELECT 1 FROM public.hiring_reference_contacts rc WHERE rc.candidate_id = hc.id)
  LOOP
    v_prog := public.hiring_reference_progress(c.id);
    CONTINUE WHEN COALESCE((v_prog ->> 'complete')::boolean, false);

    SELECT string_agg(COALESCE(x.caller_name, 'whoever is calling'), ' or ')
    INTO v_caller FROM public.hiring_reference_callers(c.id) x;
    v_caller := COALESCE(v_caller, 'whoever is calling');

    -- 1. A contact that has had its three tries this round is unreachable.
    UPDATE public.hiring_reference_contacts
    SET outcome = 'unreachable', updated_at = now()
    WHERE candidate_id = c.id
      AND outcome = 'pending'
      AND attempt_count >= 3 * GREATEST(COALESCE(round, 1), 1);
    GET DIAGNOSTICS v_stuck = ROW_COUNT;
    v_exhausted := v_exhausted + v_stuck;

    -- 2. Three days after the candidate was asked for help, reopen.
    IF c.reference_round2_opens_at IS NOT NULL
       AND c.reference_round2_opens_at <= now()
       AND NOT EXISTS (SELECT 1 FROM public.hiring_reference_contacts rc
                       WHERE rc.candidate_id = c.id AND rc.round >= 2) THEN

      UPDATE public.hiring_reference_contacts
      SET round = 2, outcome = 'pending', updated_at = now()
      WHERE candidate_id = c.id AND round = 1 AND outcome = 'unreachable';
      GET DIAGNOSTICS v_stuck = ROW_COUNT;

      IF v_stuck > 0 THEN
        v_reopened := v_reopened + 1;

        -- the nudge clock restarts, so an untouched round two gets nagged too
        UPDATE public.hiring_candidates
        SET reference_caller_nudged_at = NULL,
            reference_caller_notified_at = now(),
            updated_at = now()
        WHERE id = c.id;

        SELECT string_agg(rc.contact_name || COALESCE(' (' || rc.phone || ')', ''), ', '
                          ORDER BY rc.slot_number)
        INTO v_list_tg
        FROM public.hiring_reference_contacts rc
        WHERE rc.candidate_id = c.id AND rc.round = 2;

        PERFORM public.telegram_send('admin',
          '<b>Second round of reference calls — ' || c.name || '</b>' || E'\n'
          || c.name || ' was asked three days ago to get these people to pick up. '
          || 'They are open again for three more tries: ' || COALESCE(v_list_tg, '') || E'\n\n'
          || v_link, p_agency_id, 'HTML');

        FOR k IN SELECT * FROM public.hiring_reference_callers(c.id) LOOP
          CONTINUE WHEN k.caller_email IS NULL;
          PERFORM public.composio_send_email(p_agency_id, k.caller_email,
            'Try ' || c.name || '''s references again',
            '<p>Hi ' || COALESCE(split_part(k.caller_name,' ',1),'there') || ',</p>'
            || '<p>We asked <b>' || c.name || '</b> three days ago to tell these references we are calling. '
            || 'Please give them three more tries:</p><p>' || COALESCE(v_list_tg,'') || '</p>'
            || '<p><a href="' || v_link || '">Open the reference calls page</a></p>');
        END LOOP;
      END IF;
    END IF;

    -- 3. Nothing left to try this round?
    SELECT count(*) INTO v_pending
    FROM public.hiring_reference_contacts rc
    WHERE rc.candidate_id = c.id AND rc.outcome = 'pending';

    CONTINUE WHEN v_pending > 0;

    SELECT count(*) INTO v_stuck
    FROM public.hiring_reference_contacts rc
    WHERE rc.candidate_id = c.id AND rc.outcome IN ('unreachable','declined_to_speak');

    -- Everyone answered and we are only short of SCORED write-ups. That is not
    -- an escalation, it is work on our side. Leave it alone.
    CONTINUE WHEN v_stuck = 0;

    SELECT string_agg('<li>' || rc.contact_name
                      || COALESCE(' — ' || rc.relationship, '')
                      || COALESCE(' (' || rc.phone || ')', '') || '</li>', ''
                      ORDER BY rc.slot_number),
           string_agg(rc.contact_name, ', ' ORDER BY rc.slot_number)
    INTO v_list_html, v_list_tg
    FROM public.hiring_reference_contacts rc
    WHERE rc.candidate_id = c.id AND rc.outcome IN ('unreachable','declined_to_speak');

    IF c.reference_help_email_sent_at IS NULL THEN
      -- 3a. First ask for help, and start the three-day clock.
      IF c.email IS NOT NULL THEN
        SELECT * INTO em FROM public.render_hiring_email(p_agency_id, 'reference_help_request',
          jsonb_build_object(
            'first_name', COALESCE(c.first_name, c.name),
            'unreachable_list', '<ul>' || COALESCE(v_list_html,'') || '</ul>',
            'caller_name', v_caller,
            'caller_phone_line', '',
            'minimum', (v_prog ->> 'minimum')));
        PERFORM public.composio_send_email(p_agency_id, c.email, em.subject, em.body_html);
      END IF;

      UPDATE public.hiring_candidates
      SET reference_help_email_sent_at = now(),
          reference_round2_opens_at    = now() + interval '3 days',
          updated_at                   = now()
      WHERE id = c.id;
      v_helped := v_helped + 1;

      PERFORM public.telegram_send('admin',
        '<b>References not answering — ' || c.name || '</b>' || E'\n'
        || 'Could not reach: ' || COALESCE(v_list_tg,'') || E'\n'
        || c.name || ' has been emailed and asked to get them to pick up. '
        || 'We try again in three days.', p_agency_id, 'HTML');

    ELSIF EXISTS (SELECT 1 FROM public.hiring_reference_contacts rc
                  WHERE rc.candidate_id = c.id AND rc.round >= 2)
          AND c.reference_final_email_sent_at IS NULL THEN
      -- 3b. Second round failed too. One last email.
      IF c.email IS NOT NULL THEN
        SELECT * INTO em FROM public.render_hiring_email(p_agency_id, 'reference_final_request',
          jsonb_build_object(
            'first_name', COALESCE(c.first_name, c.name),
            'unreachable_list', '<ul>' || COALESCE(v_list_html,'') || '</ul>',
            'caller_name', v_caller,
            'caller_phone_line', '',
            'minimum', (v_prog ->> 'minimum')));
        PERFORM public.composio_send_email(p_agency_id, c.email, em.subject, em.body_html);
      END IF;

      UPDATE public.hiring_candidates
      SET reference_final_email_sent_at = now(), updated_at = now()
      WHERE id = c.id;
      v_final := v_final + 1;

      PERFORM public.telegram_send('admin',
        '<b>Final reference email sent — ' || c.name || '</b>' || E'\n'
        || 'Two rounds of calls and we still cannot reach: ' || COALESCE(v_list_tg,'') || E'\n'
        || 'If nothing comes back, this reference check pauses.', p_agency_id, 'HTML');

    ELSIF c.reference_final_email_sent_at IS NOT NULL THEN
      -- 3c. Out of road. Stop the process and tell Peter.
      UPDATE public.hiring_candidates
      SET reference_paused_at     = now(),
          reference_paused_reason = 'Only ' || (v_prog ->> 'positive')
                                    || ' of the ' || (v_prog ->> 'minimum')
                                    || ' good references we need. Could not reach: '
                                    || COALESCE(v_list_tg, 'several referees')
                                    || '. Two rounds of calls and two emails to the candidate.',
          updated_at              = now()
      WHERE id = c.id;
      v_paused := v_paused + 1;

      INSERT INTO public.alerts
        (agency_id, alert_type, severity, title, message, module_reference, related_id)
      VALUES (p_agency_id, 'reference_check_paused', 'warning',
              'Reference check paused: ' || c.name,
              'We have ' || (v_prog ->> 'positive') || ' good references and need '
              || (v_prog ->> 'minimum') || '. Could not reach ' || COALESCE(v_list_tg,'them')
              || ' after two rounds of calls and two emails. This hire does not move until you decide.',
              'hiring', c.id);

      PERFORM public.telegram_send('admin',
        '<b>Reference check PAUSED — ' || c.name || '</b>' || E'\n'
        || 'We have ' || (v_prog ->> 'positive') || ' good references and need '
        || (v_prog ->> 'minimum') || '.' || E'\n'
        || 'Never reached: ' || COALESCE(v_list_tg,'') || E'\n\n'
        || 'Nothing moves on this hire until you decide.', p_agency_id, 'HTML');
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'records_processed', v_helped + v_reopened + v_final + v_paused,
    'output_summary', 'Reference escalation: ' || v_exhausted::text || ' contacts exhausted, '
                      || v_helped::text || ' help emails, ' || v_reopened::text || ' reopened, '
                      || v_final::text || ' final emails, ' || v_paused::text || ' paused',
    'exhausted', v_exhausted, 'help_emails', v_helped, 'reopened', v_reopened,
    'final_emails', v_final, 'paused', v_paused);
END;
$function$;

COMMENT ON FUNCTION public.hiring_reference_escalation(uuid, uuid) IS
  'The reference escalation ladder. Three attempts marks a contact unreachable; once nothing is left to try it emails the candidate for help, reopens the same contacts three days later for three more attempts, sends one final email, then pauses the reference check. Runs once a day.';
