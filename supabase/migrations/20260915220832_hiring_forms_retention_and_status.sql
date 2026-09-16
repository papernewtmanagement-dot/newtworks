-- How long the I-9 must be kept: three years after hire, or one year after they
-- leave, whichever is later.
CREATE OR REPLACE FUNCTION public.i9_retention_date(p_team_id uuid)
RETURNS date LANGUAGE sql STABLE AS $$
  SELECT GREATEST(
           COALESCE(t.hire_date, t.start_date, t.created_at::date) + INTERVAL '3 years',
           COALESCE(t.end_date, CURRENT_DATE) + INTERVAL '1 year'
         )::date
  FROM public.team t WHERE t.id = p_team_id;
$$;

-- Stamp the retention date and the lock the moment the employer section is done.
CREATE OR REPLACE FUNCTION public.tg_team_form_lock()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
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

  RETURN NEW;
END;
$$;

CREATE TRIGGER team_form_lock BEFORE INSERT OR UPDATE ON public.team_form_submissions
  FOR EACH ROW EXECUTE FUNCTION public.tg_team_form_lock();

-- Which cycle each form is currently being asked for.
CREATE OR REPLACE FUNCTION public.current_form_cycle(p_agency_id uuid, p_form_type text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE p_form_type
    WHEN 'annual_certification' THEN to_char(CURRENT_DATE,'YYYY')
    WHEN 'handbook_ack' THEN COALESCE(
      (SELECT 'v'||d.version FROM public.form_documents d
        WHERE d.agency_id=p_agency_id AND d.doc_type='handbook' AND d.is_current),'')
    WHEN 'non_compete' THEN COALESCE(
      (SELECT 'v'||d.version FROM public.form_documents d
        WHERE d.agency_id=p_agency_id AND d.doc_type='non_compete' AND d.is_current),'')
    ELSE ''
  END;
$$;

-- One row per active team member per form. This is what drives "Action needed"
-- in Development and the summary on the team record.
CREATE OR REPLACE VIEW public.v_team_form_status AS
SELECT
  t.id                AS team_id,
  t.agency_id,
  t.first_name,
  t.last_name,
  f.form_type,
  public.current_form_cycle(t.agency_id, f.form_type) AS required_cycle,
  s.id                AS submission_id,
  s.status,
  s.employee_submitted_at,
  s.employer_completed_at,
  s.locked_at,
  s.retention_until,
  CASE
    WHEN s.id IS NULL THEN 'action_needed'
    WHEN f.form_type = 'i9' AND s.employer_completed_at IS NULL THEN 'awaiting_employer'
    WHEN s.status IN ('submitted','locked') THEN 'complete'
    ELSE 'action_needed'
  END AS state
FROM public.team t
CROSS JOIN (VALUES ('combined_onboarding'),('non_compete'),('annual_certification'),
                   ('handbook_ack'),('i9')) AS f(form_type)
LEFT JOIN public.team_form_submissions s
  ON s.team_id = t.id
 AND s.form_type = f.form_type
 AND s.cycle_key = public.current_form_cycle(t.agency_id, f.form_type)
 AND s.status <> 'superseded'
WHERE t.is_active IS TRUE AND COALESCE(t.is_test_user, false) = false;
