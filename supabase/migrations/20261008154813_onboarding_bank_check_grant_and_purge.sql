GRANT EXECUTE ON FUNCTION public.onboarding_bank_complete(jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.onboarding_bank_on_file(p_team_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM public.require_login('staff');
  IF NOT (p_team_id = public.current_team_member_id() OR public.is_agency_admin()) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  RETURN EXISTS (
           SELECT 1
           FROM public.team_form_secure sec
           JOIN public.team_form_submissions s ON s.id = sec.submission_id
           WHERE s.team_id = p_team_id
             AND s.form_type = 'combined_onboarding'
             AND public.onboarding_bank_complete(sec.banks))
      OR EXISTS (
           SELECT 1 FROM public.team_form_submissions s
           WHERE s.team_id = p_team_id
             AND s.form_type = 'combined_onboarding'
             AND s.secure_purged_at IS NOT NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_ssn_on_file(p_team_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('staff');
  IF NOT (p_team_id = public.current_team_member_id() OR public.is_agency_admin()) THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;
  RETURN EXISTS (
           SELECT 1
           FROM public.team_form_secure sec
           JOIN public.hiring_candidates hc ON hc.id = sec.candidate_id
           WHERE hc.team_member_id = p_team_id
             AND sec.submission_id IS NULL
             AND sec.ssn IS NOT NULL)
      OR EXISTS (
           SELECT 1
           FROM public.team_form_secure sec
           JOIN public.team_form_submissions s ON s.id = sec.submission_id
           WHERE s.team_id = p_team_id
             AND s.form_type = 'combined_onboarding'
             AND sec.ssn IS NOT NULL)
      OR EXISTS (
           SELECT 1 FROM public.team_form_submissions s
           WHERE s.team_id = p_team_id
             AND s.form_type = 'combined_onboarding'
             AND s.secure_purged_at IS NOT NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.tg_team_form_lock()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.form_type = 'combined_onboarding' AND NEW.status = 'submitted' AND NEW.locked_at IS NULL THEN
    IF length(btrim(coalesce(NEW.data->>'need_to_make', ''))) = 0
       OR length(btrim(coalesce(NEW.data->>'want_to_make', ''))) = 0 THEN
      RAISE EXCEPTION 'Fill in what you need to make and what you want to make, then press Submit again.';
    END IF;
    IF NEW.secure_purged_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.team_form_secure sec
                       WHERE sec.submission_id = NEW.id
                         AND public.onboarding_bank_complete(sec.banks)) THEN
      RAISE EXCEPTION 'Fill in your bank name, 9-digit routing number and account number, then press Submit again.';
    END IF;
  END IF;

  IF NEW.status = 'submitted' AND NEW.employee_submitted_at IS NULL THEN
    NEW.employee_submitted_at := now();
  END IF;

  IF NEW.form_type = 'i9' THEN
    NEW.retention_until := public.i9_retention_date(NEW.team_id);
    IF NEW.employer_completed_at IS NOT NULL AND NEW.locked_at IS NULL THEN
      NEW.locked_at := now();
      NEW.status := 'locked';
    END IF;
  ELSIF NEW.status = 'submitted' AND NEW.locked_at IS NULL THEN
    NEW.locked_at := now();
    NEW.status := 'locked';
  END IF;

  IF NEW.form_type = 'w4' AND NEW.locked_at IS NOT NULL AND NEW.retention_until IS NULL THEN
    NEW.retention_until := (NEW.locked_at + interval '4 years')::date;
  END IF;

  RETURN NEW;
END;
$function$;
