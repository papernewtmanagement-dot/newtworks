-- Without this the view runs with the owner's rights and quietly hands every
-- signed-in person everyone else's form status. security_invoker makes it obey
-- the same policies the tables underneath it have.
ALTER VIEW public.v_team_form_status SET (security_invoker = true);
GRANT SELECT ON public.v_team_form_status TO authenticated;

-- alert_type lined up with how the rest of the alerts table reads.
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
  SELECT p_agency_id, 'unpurged_payroll_details', 'high',
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
