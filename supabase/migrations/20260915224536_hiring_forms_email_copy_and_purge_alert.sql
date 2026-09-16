-- The agreement text says the signer has received a copy, so send them one.
CREATE OR REPLACE FUNCTION public.tg_email_non_compete_copy()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_to text; v_doc public.form_documents%ROWTYPE; v_name text;
BEGIN
  IF NEW.form_type <> 'non_compete' OR NEW.status NOT IN ('submitted','locked') THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.status IN ('submitted','locked') THEN RETURN NEW; END IF;

  SELECT COALESCE(t.email_sf, t.email_personal), t.first_name || ' ' || t.last_name
    INTO v_to, v_name
    FROM public.team t WHERE t.id = NEW.team_id;
  IF v_to IS NULL THEN RETURN NEW; END IF;

  SELECT * INTO v_doc FROM public.form_documents WHERE id = NEW.document_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  PERFORM public.composio_send_email(
    NEW.agency_id, v_to,
    'Your copy — ' || v_doc.title,
    '<p>' || v_name || ',</p><p>You agreed to the ' || v_doc.title ||
    ' on ' || to_char(COALESCE(NEW.employee_submitted_at, now()), 'Mon DD, YYYY') ||
    '. Your copy is below.</p><hr><pre style="white-space:pre-wrap;font-family:Georgia,serif;font-size:14px">' ||
    replace(replace(COALESCE(v_doc.body,''), '&', '&amp;'), '<', '&lt;') ||
    '</pre><hr><p>Peter Story State Farm Agency</p>');
  RETURN NEW;
END;
$$;

CREATE TRIGGER email_non_compete_copy AFTER INSERT OR UPDATE
  ON public.team_form_submissions
  FOR EACH ROW EXECUTE FUNCTION public.tg_email_non_compete_copy();

-- Bank details and Social Security numbers should not sit around. One alert if
-- any are still here three days after they were submitted.
CREATE OR REPLACE FUNCTION public.alert_unpurged_form_secure(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_names text; v_count integer;
BEGIN
  SELECT count(*), string_agg(t.first_name || ' ' || left(t.last_name,1) || '.', ', ')
    INTO v_count, v_names
    FROM public.team_form_secure sec
    JOIN public.team_form_submissions s ON s.id = sec.submission_id
    JOIN public.team t ON t.id = s.team_id
   WHERE sec.created_at < now() - INTERVAL '3 days';

  IF COALESCE(v_count,0) = 0 THEN RETURN 0; END IF;

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_resolved)
  SELECT p_agency_id, 'compliance', 'high',
         'Bank details still stored for ' || v_count || ' team member(s)',
         v_names || ' submitted payroll details more than three days ago and they have not been destroyed yet. ' ||
         'Enter them in SurePayroll, then press Destroy on the team record.',
         'team', false
  WHERE NOT EXISTS (
    SELECT 1 FROM public.alerts a
     WHERE a.agency_id = p_agency_id AND a.is_resolved = false
       AND a.title LIKE 'Bank details still stored%');
  RETURN v_count;
END;
$$;

INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
   composio_action, internal_handler, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Unpurged payroll details alert',
       'Once a day. Raises one alert if a Social Security number or bank details from the onboarding form have been sitting in the database for more than three days. Clears when the Destroy button is pressed on the team record.',
       'cron', '59 9 * * *', 'INTERNAL', 'alert_unpurged_form_secure', true, 'America/Chicago'
WHERE NOT EXISTS (SELECT 1 FROM public.automation_recipes
                  WHERE recipe_name = 'Unpurged payroll details alert');
