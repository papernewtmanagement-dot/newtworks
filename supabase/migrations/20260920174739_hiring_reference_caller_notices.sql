-- Item 3. Tell the caller their three contacts are in, then nag if the calls
-- do not start.
--
-- Two jobs, one pass, because both read the same candidate list:
--   NOTIFY  every contact is in and the caller has not been told  -> email each
--           caller, post to Telegram route admin, stamp notified_at.
--   NUDGE   told two days ago and not one number has been tried   -> Telegram
--           route admin, once a day, until a call is logged.
--
-- Two days of grace before the first nag: one working day to get to it. Route
-- is admin, never team, because this is candidate-level hiring detail.

CREATE OR REPLACE FUNCTION public.hiring_reference_caller_notices(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_recipe_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  c          record;
  k          record;
  v_base     text;
  v_link     text;
  v_prog     jsonb;
  v_have     int;
  v_asked    int;
  v_names    text;
  v_rows_tg  text;
  v_rows_html text;
  v_html     text;
  v_tg       text;
  v_notified int := 0;
  v_emails   int := 0;
  v_nudged   int := 0;
BEGIN
  v_base := COALESCE(public.get_setting(p_agency_id, 'app_base_url'), 'https://newtworks.vercel.app');
  v_link := v_base || '/references';

  FOR c IN
    SELECT hc.id, hc.agency_id,
           COALESCE(NULLIF(TRIM(COALESCE(hc.first_name,'') || ' ' || COALESCE(hc.last_name,'')), ''),
                    hc.candidate_name, 'the candidate') AS name,
           hc.offer_job_title, hc.offer_start_date,
           hc.reference_caller_notified_at, hc.reference_caller_nudged_at
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.reference_paused_at IS NULL
      AND EXISTS (SELECT 1 FROM public.hiring_reference_contacts rc WHERE rc.candidate_id = hc.id)
  LOOP
    v_prog  := public.hiring_reference_progress(c.id);
    CONTINUE WHEN COALESCE((v_prog ->> 'complete')::boolean, false);

    v_asked := COALESCE((v_prog ->> 'asked_for')::int, 3);
    SELECT count(*) INTO v_have
    FROM public.hiring_reference_contacts rc WHERE rc.candidate_id = c.id;

    -- ---- NOTIFY -----------------------------------------------------------
    IF c.reference_caller_notified_at IS NULL AND v_have >= v_asked THEN

      SELECT string_agg(
               rc.slot_number || '. ' || rc.contact_name
               || COALESCE(' — ' || rc.relationship, '')
               || COALESCE(' at ' || rc.company, '')
               || COALESCE(E'\n   ' || rc.phone, '')
               || COALESCE(E'\n   ' || rc.email, ''),
               E'\n' ORDER BY rc.slot_number),
             string_agg(
               '<li><b>' || rc.contact_name || '</b>'
               || COALESCE(' — ' || rc.relationship, '')
               || COALESCE(' at ' || rc.company, '')
               || COALESCE('<br>' || rc.phone, '')
               || COALESCE('<br>' || rc.email, '')
               || '</li>',
               '' ORDER BY rc.slot_number)
      INTO v_rows_tg, v_rows_html
      FROM public.hiring_reference_contacts rc WHERE rc.candidate_id = c.id;

      SELECT string_agg(COALESCE(x.caller_name, 'the caller'), ', ')
      INTO v_names FROM public.hiring_reference_callers(c.id) x;

      v_tg := '<b>Reference calls ready — ' || c.name || '</b>' || E'\n'
              || c.name || ' accepted the offer and gave '
              || v_have::text || ' references. '
              || COALESCE(v_names, 'The caller') || ' has been emailed.' || E'\n\n'
              || COALESCE(v_rows_tg, '') || E'\n\n'
              || 'Log each call here: ' || v_link;

      PERFORM public.telegram_send('admin', v_tg, p_agency_id, 'HTML');

      FOR k IN SELECT * FROM public.hiring_reference_callers(c.id) LOOP
        CONTINUE WHEN k.caller_email IS NULL;

        v_html := '<p>Hi ' || COALESCE(split_part(k.caller_name, ' ', 1), 'there') || ',</p>'
               || '<p><b>' || c.name || '</b> accepted the offer'
               || COALESCE(' for ' || c.offer_job_title, '')
               || CASE WHEN c.offer_start_date IS NULL THEN ''
                       ELSE ', starting ' || to_char(c.offer_start_date, 'Dy Mon FMDD') END
               || ', and gave us ' || v_have::text || ' references to call.</p>'
               || '<ul>' || COALESCE(v_rows_html, '') || '</ul>'
               || '<p>We need ' || (v_prog ->> 'minimum')
               || ' good ones before this hire can go ahead, so please start on these.</p>'
               || '<p><a href="' || v_link || '">Open the reference calls page in Newtworks</a></p>'
               || '<p>Log every attempt on that page, even the ones nobody picks up. '
               || 'After three tries on a number we email ' || c.name
               || ' and ask them to get that person to call you.</p>';

        PERFORM public.composio_send_email(
          p_agency_id, k.caller_email,
          'Reference calls for ' || c.name, v_html);
        v_emails := v_emails + 1;
      END LOOP;

      UPDATE public.hiring_candidates
      SET reference_caller_notified_at = now(), updated_at = now()
      WHERE id = c.id;
      v_notified := v_notified + 1;

    -- ---- NUDGE ------------------------------------------------------------
    ELSIF c.reference_caller_notified_at IS NOT NULL
      AND c.reference_caller_notified_at < now() - interval '48 hours'
      AND (c.reference_caller_nudged_at IS NULL
           OR c.reference_caller_nudged_at < now() - interval '24 hours')
      AND EXISTS (SELECT 1 FROM public.hiring_reference_contacts rc
                  WHERE rc.candidate_id = c.id
                    AND rc.outcome = 'pending'
                    AND rc.attempt_count = 0)
    THEN
      SELECT string_agg(rc.contact_name || COALESCE(' (' || rc.phone || ')', ''), ', '
                        ORDER BY rc.slot_number)
      INTO v_rows_tg
      FROM public.hiring_reference_contacts rc
      WHERE rc.candidate_id = c.id AND rc.outcome = 'pending' AND rc.attempt_count = 0;

      SELECT string_agg(COALESCE(x.caller_name, 'the caller'), ', ')
      INTO v_names FROM public.hiring_reference_callers(c.id) x;

      v_tg := '<b>Reference calls not started — ' || c.name || '</b>' || E'\n'
              || COALESCE(v_names, 'The caller') || ' was asked on '
              || to_char(c.reference_caller_notified_at, 'Dy Mon FMDD')
              || ' and nobody has been tried yet.' || E'\n\n'
              || 'Still untried: ' || COALESCE(v_rows_tg, '') || E'\n\n'
              || v_link;

      PERFORM public.telegram_send('admin', v_tg, p_agency_id, 'HTML');

      UPDATE public.hiring_candidates
      SET reference_caller_nudged_at = now(), updated_at = now()
      WHERE id = c.id;
      v_nudged := v_nudged + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'records_processed', v_notified + v_nudged,
    'output_summary', 'Reference caller notices: ' || v_notified::text
                      || ' notified, ' || v_emails::text || ' emails, '
                      || v_nudged::text || ' nudged',
    'notified', v_notified, 'emails', v_emails, 'nudged', v_nudged);
END;
$function$;

COMMENT ON FUNCTION public.hiring_reference_caller_notices(uuid, uuid) IS
  'Emails whoever is calling a candidate references once all the contacts are in, and nags Telegram route admin daily from 48 hours on while a number still has not been tried. Runs on the hourly tick through the working day.';
