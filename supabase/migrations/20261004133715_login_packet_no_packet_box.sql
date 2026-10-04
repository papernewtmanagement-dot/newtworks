-- Peter 2026-10-04, 1A: a "No packet for this hire" box on the Login Packet
-- Info form. Former State Farm and fully remote hires get no packet; ticking
-- the box checks his Fill in Login Packet Info line off, the same as filling
-- in every detail does.

ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS sf_no_login_packet boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.team.sf_no_login_packet IS 'Peter ticked "No packet for this hire" on the Login Packet Info form. Former State Farm and fully remote hires get no packet. Marks the login_packet_info form waived, which checks his line off.';

-- Same view. The packet line is waived when the box is ticked, complete once
-- all six details are in, and needs action otherwise.

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
            WHEN s.id IS NULL THEN 'action_needed'::text
            WHEN f.form_type = 'i9'::text AND s.employer_completed_at IS NULL THEN 'awaiting_employer'::text
            WHEN s.status = ANY (ARRAY['submitted'::text, 'locked'::text]) THEN 'complete'::text
            ELSE 'action_needed'::text
        END AS state
   FROM team t
     CROSS JOIN ( VALUES ('combined_onboarding'::text), ('w4'::text), ('non_compete'::text), ('handbook_ack'::text), ('i9'::text)) f(form_type)
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
  WHERE (t.is_active IS TRUE OR t.archived_at IS NULL AND t.end_date IS NULL AND t.start_date IS NOT NULL AND t.start_date <= CURRENT_DATE) AND COALESCE(t.is_test_user, false) = false
UNION ALL
 SELECT t.id AS team_id,
    t.agency_id,
    t.first_name,
    t.last_name,
    'login_packet_info'::text AS form_type,
    NULL::uuid AS submission_id,
    NULL::text AS submission_status,
    NULL::timestamp with time zone AS employee_submitted_at,
    NULL::timestamp with time zone AS employer_completed_at,
    NULL::timestamp with time zone AS locked_at,
    NULL::date AS retention_until,
    NULL::timestamp with time zone AS secure_purged_at,
    NULL::date AS due_date,
    NULL::date AS last_completed_at,
    NULL::integer AS cycle_months,
        CASE
            WHEN t.sf_no_login_packet THEN 'waived'::text
            WHEN NULLIF(btrim(t.sf_alias), '') IS NOT NULL
             AND NULLIF(btrim(t.sf_registration_number), '') IS NOT NULL
             AND NULLIF(btrim(t.sf_initial_password), '') IS NOT NULL
             AND NULLIF(btrim(t.sf_mfa_temp_pass), '') IS NOT NULL
             AND t.sf_mfa_temp_pass_from IS NOT NULL
             AND t.sf_mfa_temp_pass_until IS NOT NULL THEN 'complete'::text
            ELSE 'action_needed'::text
        END AS state
   FROM team t
  WHERE COALESCE(t.is_test_user, false) = false
    AND (EXISTS ( SELECT 1
           FROM team_onboarding_plans p
          WHERE p.team_member_id = t.id AND (p.status = ANY (ARRAY['active'::text, 'paused'::text]))));

-- Ticking or clearing the box re-checks that person's lines right away, the
-- same way saving the details does.
DROP TRIGGER IF EXISTS trg_onboarding_packet_info_changed ON public.team;
CREATE TRIGGER trg_onboarding_packet_info_changed
  AFTER UPDATE OF sf_alias, sf_registration_number, sf_initial_password, sf_mfa_temp_pass, sf_mfa_temp_pass_from, sf_mfa_temp_pass_until, sf_no_login_packet
  ON public.team
  FOR EACH ROW
  WHEN ((old.sf_alias, old.sf_registration_number, old.sf_initial_password, old.sf_mfa_temp_pass, old.sf_mfa_temp_pass_from, old.sf_mfa_temp_pass_until, old.sf_no_login_packet)
        IS DISTINCT FROM
        (new.sf_alias, new.sf_registration_number, new.sf_initial_password, new.sf_mfa_temp_pass, new.sf_mfa_temp_pass_from, new.sf_mfa_temp_pass_until, new.sf_no_login_packet))
  EXECUTE FUNCTION public.tg_onboarding_forms_changed();

