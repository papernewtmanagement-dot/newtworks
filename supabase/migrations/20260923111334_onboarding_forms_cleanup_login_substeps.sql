-- Peter 2026-09-23.
-- * The Annual Certification form is gone from the site (it is attested in
--   State Farm's own login steps now): off the status view, off the allowed
--   form types, its six open "due" rows deleted (nobody had submitted one).
-- * Paperwork card: "Payroll and Bio" is now "Onboarding"; the annual
--   certification line comes off.
-- * Login card: three steps nested under the Yubikey step (two leading
--   spaces = nested under the line above).

CREATE OR REPLACE VIEW public.v_team_form_status AS
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
  WHERE (t.is_active IS TRUE OR t.archived_at IS NULL AND t.end_date IS NULL AND t.start_date IS NOT NULL AND t.start_date <= CURRENT_DATE) AND COALESCE(t.is_test_user, false) = false;
ALTER VIEW public.v_team_form_status SET (security_invoker = true);

DELETE FROM public.team_form_requirements WHERE form_type = 'annual_certification';

ALTER TABLE public.team_form_submissions DROP CONSTRAINT IF EXISTS team_form_submissions_form_type_check;
ALTER TABLE public.team_form_submissions ADD CONSTRAINT team_form_submissions_form_type_check
  CHECK (form_type = ANY (ARRAY['combined_onboarding','w4','non_compete','handbook_ack','i9']));

SELECT set_config('app.onboarding_template_sync', 'off', true);

UPDATE public.onboarding_step_templates t
   SET substeps = (
     SELECT jsonb_agg(CASE WHEN x = '[Payroll and Bio](/development?area=forms&form=combined_onboarding)'
                           THEN '[Onboarding](/development?area=forms&form=combined_onboarding)' ELSE x END
                      ORDER BY o)
     FROM jsonb_array_elements_text(t.substeps) WITH ORDINALITY z(x, o)
     WHERE x <> '[State Farm Annual Certification](/development?area=forms&form=annual_certification)')
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = 'p1_paperwork_pack'
   AND jsonb_typeof(t.substeps) = 'array'
   AND t.substeps ? '[Payroll and Bio](/development?area=forms&form=combined_onboarding)';

UPDATE public.onboarding_step_templates t
   SET substeps = (
     SELECT jsonb_agg(
              CASE WHEN jsonb_typeof(e) = 'object' AND e -> 'items' ? 'Follow Login packet steps to setup Yubikey'
                        AND NOT (e -> 'items' ? '  Set password')
                   THEN jsonb_set(e, '{items}', (
                          SELECT jsonb_agg(y ORDER BY o, k)
                          FROM jsonb_array_elements_text(e -> 'items') WITH ORDINALITY z(x, o),
                               LATERAL (
                                 SELECT x AS y, 0 AS k
                                 UNION ALL
                                 SELECT v, n FROM unnest(ARRAY['  Set password', '  Set security questions',
                                                               '  Attest to State Farm Annual Certification'])
                                                  WITH ORDINALITY w(v, n)
                                 WHERE x = 'Follow Login packet steps to setup Yubikey'
                               ) ins))
                   ELSE e END
              ORDER BY ord)
     FROM jsonb_array_elements(t.substeps) WITH ORDINALITY q(e, ord))
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND t.template_key = 't_login';

SELECT set_config('app.onboarding_template_sync', 'on', true);
SELECT public.onboarding_sync_open_plans();
SELECT public.onboarding_sync_form_steps(NULL);
