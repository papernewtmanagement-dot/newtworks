-- The destroy button on the team record.
ALTER TABLE public.team_form_submissions
  ADD COLUMN IF NOT EXISTS secure_purged_at timestamptz,
  ADD COLUMN IF NOT EXISTS secure_purged_by uuid REFERENCES public.team(id);

-- Hard delete. The Social Security number and every bank row are gone. What
-- survives is the fact that it happened, who did it, and when.
CREATE OR REPLACE FUNCTION public.purge_team_form_secure(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_deleted integer := 0; v_by uuid;
BEGIN
  IF NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'Not permitted';
  END IF;

  v_by := public.current_team_member_id();

  WITH target AS (
    SELECT sec.id
      FROM public.team_form_secure sec
      JOIN public.team_form_submissions s ON s.id = sec.submission_id
     WHERE s.team_id = p_team_id
  ), gone AS (
    DELETE FROM public.team_form_secure
     WHERE id IN (SELECT id FROM target)
     RETURNING 1
  )
  SELECT count(*) INTO v_deleted FROM gone;

  UPDATE public.team_form_submissions
     SET secure_purged_at = now(), secure_purged_by = v_by
   WHERE team_id = p_team_id
     AND form_type = 'combined_onboarding'
     AND secure_purged_at IS NULL;

  RETURN jsonb_build_object('deleted', v_deleted, 'purged_at', now());
END;
$$;

REVOKE ALL ON FUNCTION public.purge_team_form_secure(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.purge_team_form_secure(uuid) TO authenticated;

-- Status view rebuilt: recurring forms read off the standing record.
DROP VIEW IF EXISTS public.v_team_form_status;
CREATE VIEW public.v_team_form_status AS
SELECT
  t.id AS team_id, t.agency_id, t.first_name, t.last_name,
  f.form_type,
  s.id AS submission_id,
  s.status AS submission_status,
  s.employee_submitted_at,
  s.employer_completed_at,
  s.locked_at,
  s.retention_until,
  s.secure_purged_at,
  r.due_date,
  r.last_completed_at,
  r.cycle_months,
  CASE
    WHEN f.form_type IN ('annual_certification','handbook_ack') THEN
      CASE WHEN r.id IS NULL OR r.status IN ('due','active') THEN 'action_needed'
           WHEN r.due_date <= CURRENT_DATE AND r.cycle_months IS NOT NULL THEN 'action_needed'
           WHEN r.status = 'waived' THEN 'waived'
           ELSE 'complete' END
    WHEN s.id IS NULL THEN 'action_needed'
    WHEN f.form_type = 'i9' AND s.employer_completed_at IS NULL THEN 'awaiting_employer'
    WHEN s.status IN ('submitted','locked') THEN 'complete'
    ELSE 'action_needed'
  END AS state
FROM public.team t
CROSS JOIN (VALUES ('combined_onboarding'),('non_compete'),('annual_certification'),
                   ('handbook_ack'),('i9')) AS f(form_type)
LEFT JOIN public.team_form_requirements r
  ON r.team_member_id = t.id AND r.form_type = f.form_type
LEFT JOIN LATERAL (
  SELECT s2.* FROM public.team_form_submissions s2
   WHERE s2.team_id = t.id AND s2.form_type = f.form_type AND s2.status <> 'superseded'
   ORDER BY s2.created_at DESC LIMIT 1
) s ON true
WHERE t.is_active IS TRUE AND COALESCE(t.is_test_user, false) = false;
