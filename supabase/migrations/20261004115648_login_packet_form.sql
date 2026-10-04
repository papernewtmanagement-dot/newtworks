-- Login Packet: State Farm's New Agent/Agent Team Member Onboarding Packet as a
-- site form. The lines that differ for each person live on their team record.
-- Team rows are readable only by admins and the person themselves
-- (team_admin_or_own_read), and team_directory lists its columns by name, so
-- these never reach anyone else.

ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS sf_registration_number text,
  ADD COLUMN IF NOT EXISTS sf_initial_password text,
  ADD COLUMN IF NOT EXISTS sf_mfa_temp_pass text,
  ADD COLUMN IF NOT EXISTS sf_mfa_temp_pass_from timestamptz,
  ADD COLUMN IF NOT EXISTS sf_mfa_temp_pass_until timestamptz;

COMMENT ON COLUMN public.team.sf_registration_number IS 'Registration Number from the State Farm login packet.';
COMMENT ON COLUMN public.team.sf_initial_password IS 'Initial computer/workstation password from the State Farm login packet. They change it at first logon.';
COMMENT ON COLUMN public.team.sf_mfa_temp_pass IS 'Initial MFA Temporary Access Pass from the State Farm login packet.';
COMMENT ON COLUMN public.team.sf_mfa_temp_pass_from IS 'When the MFA Temporary Access Pass starts working (packet: Good from).';
COMMENT ON COLUMN public.team.sf_mfa_temp_pass_until IS 'When the MFA Temporary Access Pass stops working (packet: Until).';

ALTER TABLE public.team_form_submissions
  DROP CONSTRAINT IF EXISTS team_form_submissions_form_type_check;
ALTER TABLE public.team_form_submissions
  ADD CONSTRAINT team_form_submissions_form_type_check
  CHECK (form_type = ANY (ARRAY['combined_onboarding'::text, 'w4'::text, 'non_compete'::text, 'handbook_ack'::text, 'i9'::text, 'login_packet'::text]));

-- Same view, plus login_packet. The packet only matters while someone is
-- onboarding: with no open plan and nothing submitted it reads 'waived', and
-- the forms list hides it. security_invoker stays on, or the view would run
-- with the owner's rights and show everyone's status to everyone.
CREATE OR REPLACE VIEW public.v_team_form_status WITH (security_invoker = true) AS
 SELECT t.id AS team_id,
    t.agency_id,
    t.first_name,
    t.last_name,
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
            WHEN f.form_type = 'handbook_ack'::text THEN
            CASE
                WHEN r.id IS NULL OR (r.status = ANY (ARRAY['due'::text, 'active'::text])) THEN 'action_needed'::text
                WHEN r.due_date <= CURRENT_DATE AND r.cycle_months IS NOT NULL THEN 'action_needed'::text
                WHEN r.status = 'waived'::text THEN 'waived'::text
                ELSE 'complete'::text
            END
            WHEN f.form_type = 'login_packet'::text AND s.id IS NULL AND NOT (EXISTS ( SELECT 1
               FROM team_onboarding_plans p
              WHERE p.team_member_id = t.id AND (p.status = ANY (ARRAY['active'::text, 'paused'::text])))) THEN 'waived'::text
            WHEN s.id IS NULL THEN 'action_needed'::text
            WHEN f.form_type = 'i9'::text AND s.employer_completed_at IS NULL THEN 'awaiting_employer'::text
            WHEN s.status = ANY (ARRAY['submitted'::text, 'locked'::text]) THEN 'complete'::text
            ELSE 'action_needed'::text
        END AS state
   FROM team t
     CROSS JOIN ( VALUES ('combined_onboarding'::text), ('w4'::text), ('non_compete'::text), ('handbook_ack'::text), ('i9'::text), ('login_packet'::text)) f(form_type)
     LEFT JOIN team_form_requirements r ON r.team_member_id = t.id AND r.form_type = f.form_type
     LEFT JOIN LATERAL ( SELECT s2.id,
            s2.agency_id,
            s2.team_id,
            s2.form_type,
            s2.cycle_key,
            s2.document_id,
            s2.status,
            s2.data,
            s2.employee_submitted_at,
            s2.employer_section,
            s2.employer_completed_by,
            s2.employer_completed_at,
            s2.locked_at,
            s2.retention_until,
            s2.created_at,
            s2.updated_at,
            s2.secure_purged_at,
            s2.secure_purged_by
           FROM team_form_submissions s2
          WHERE s2.team_id = t.id AND s2.form_type = f.form_type AND s2.status <> 'superseded'::text
          ORDER BY s2.created_at DESC
         LIMIT 1) s ON true
  WHERE (t.is_active IS TRUE OR t.archived_at IS NULL AND t.end_date IS NULL AND t.start_date IS NOT NULL AND t.start_date <= CURRENT_DATE) AND COALESCE(t.is_test_user, false) = false;

