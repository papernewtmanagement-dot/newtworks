CREATE OR REPLACE FUNCTION public.reopen_team_form(p_submission_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Peter 2026-10-09: an owner or manager can reopen a submitted team form so it can be
-- corrected and submitted again. Submitting again re-locks it and re-copies the
-- onboarding answers onto the team record. The I-9 is excluded: it has its own
-- employee and employer steps and a legal retention date.
DECLARE v_row public.team_form_submissions%ROWTYPE;
BEGIN
  IF NOT public.is_agency_admin() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Only an owner or manager can reopen a form.');
  END IF;
  SELECT * INTO v_row FROM public.team_form_submissions WHERE id = p_submission_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Form not found.'); END IF;
  IF v_row.form_type = 'i9' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'The I-9 cannot be reopened.');
  END IF;
  IF v_row.locked_at IS NULL THEN RETURN jsonb_build_object('ok', true, 'already_open', true); END IF;
  UPDATE public.team_form_submissions
     SET status = 'in_progress', locked_at = NULL, employee_submitted_at = NULL
   WHERE id = p_submission_id;
  RETURN jsonb_build_object('ok', true, 'id', p_submission_id, 'form_type', v_row.form_type);
END $function$;
REVOKE ALL ON FUNCTION public.reopen_team_form(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reopen_team_form(uuid) TO authenticated;
