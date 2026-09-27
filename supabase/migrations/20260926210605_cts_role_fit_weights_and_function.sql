-- Sales-profile (CTS) role fit. Peter 2026-09-26: derive a fit score per role
-- from the CTS report, ignoring the vendor's headline total, and name the best
-- fit. Approved mapping: each role averages the vendor's task scores
-- ("sales competencies") that match what the role does all day, unit weights.
--
-- SEPARATE FROM THE NEWTWORKS ASSESSMENT. Nothing here reads or writes any
-- assessment score, verdict, cached composite or assessment_best_fit_role, and
-- no scoring function reads cts_result. Read-only, computed on demand from the
-- stored report, never stored.

CREATE TABLE IF NOT EXISTS public.hiregauge_cts_role_weights (
  role_category  text NOT NULL CHECK (role_category IN (
    'sales_outbound','sales_inbound','sales_in_book',
    'retention_reception','retention_support','retention_escalation','aspirant')),
  competency_key text NOT NULL CHECK (competency_key IN (
    'maintains_high_activity','handles_rejection','prospects_in_community',
    'dials_cold_calls','listens_discovers_needs','presents_solutions',
    'gets_decisions_handles_objections_referrals','receives_coaching',
    'positively_influences_team')),
  weight     numeric NOT NULL DEFAULT 1 CHECK (weight >= 0),
  notes      text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_category, competency_key)
);

COMMENT ON TABLE public.hiregauge_cts_role_weights IS
'Which CTS task scores (sales_competencies keys, same keys the document-processor parser and the candidate-page panel use) count toward each role''s sales-profile fit. Unit weights by design: Dawes 1979 (Am Psychol 34:571), Bobko, Roth & Buster 2007 (Org Res Methods 10:689) - equal weights predict about as well as fitted weights until there is outcome data to fit them on. Task selection per role is the job-analysis step: Tett, Jackson & Rothstein 1991 (Pers Psychol 44:703) - personality scales chosen for their link to the job predict better than scales used wholesale. Read only by public.cts_role_fit(). Approved by Peter 2026-09-26.';

ALTER TABLE public.hiregauge_cts_role_weights ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS admin_read_hiregauge_cts_role_weights ON public.hiregauge_cts_role_weights;
CREATE POLICY admin_read_hiregauge_cts_role_weights ON public.hiregauge_cts_role_weights
  FOR SELECT TO authenticated USING ((SELECT public.is_agency_admin()));
DROP POLICY IF EXISTS zz_block_family_login ON public.hiregauge_cts_role_weights;
CREATE POLICY zz_block_family_login ON public.hiregauge_cts_role_weights
  AS RESTRICTIVE FOR ALL TO authenticated
  USING (NOT (SELECT public.auth_is_family()))
  WITH CHECK (NOT (SELECT public.auth_is_family()));

INSERT INTO public.hiregauge_cts_role_weights (role_category, competency_key, notes) VALUES
  ('sales_outbound','maintains_high_activity','Outbound: call volume every day'),
  ('sales_outbound','dials_cold_calls','Outbound: dialing strangers'),
  ('sales_outbound','handles_rejection','Outbound: most calls are a no'),
  ('sales_outbound','prospects_in_community','Outbound: finding people to call'),
  ('sales_outbound','gets_decisions_handles_objections_referrals','Outbound: asking for the sale'),
  ('sales_inbound','listens_discovers_needs','Inbound: finding the need on a warm lead'),
  ('sales_inbound','presents_solutions','Inbound: presenting the quote'),
  ('sales_inbound','gets_decisions_handles_objections_referrals','Inbound: closing'),
  ('sales_inbound','maintains_high_activity','Inbound: working the lead queue fast'),
  ('sales_in_book','listens_discovers_needs','In-book: finding gaps with current customers'),
  ('sales_in_book','presents_solutions','In-book: presenting the added coverage'),
  ('sales_in_book','gets_decisions_handles_objections_referrals','In-book: closing and asking for referrals'),
  ('retention_reception','listens_discovers_needs','Reception: hearing what the caller needs'),
  ('retention_reception','positively_influences_team','Reception: sets the tone of the office'),
  ('retention_reception','receives_coaching','Reception: learns the service work'),
  ('retention_support','listens_discovers_needs','Support: hearing the real service need'),
  ('retention_support','handles_rejection','Support: staying steady with upset customers'),
  ('retention_support','receives_coaching','Support: learns the service work'),
  ('retention_escalation','handles_rejection','Escalation: hard conversations'),
  ('retention_escalation','listens_discovers_needs','Escalation: getting to the real problem'),
  ('retention_escalation','presents_solutions','Escalation: presenting the way forward'),
  ('aspirant','maintains_high_activity','Aspirant: future owner, every task counts'),
  ('aspirant','handles_rejection','Aspirant: future owner, every task counts'),
  ('aspirant','prospects_in_community','Aspirant: future owner, every task counts'),
  ('aspirant','dials_cold_calls','Aspirant: future owner, every task counts'),
  ('aspirant','listens_discovers_needs','Aspirant: future owner, every task counts'),
  ('aspirant','presents_solutions','Aspirant: future owner, every task counts'),
  ('aspirant','gets_decisions_handles_objections_referrals','Aspirant: future owner, every task counts'),
  ('aspirant','receives_coaching','Aspirant: future owner, every task counts'),
  ('aspirant','positively_influences_team','Aspirant: future owner, every task counts')
ON CONFLICT (role_category, competency_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cts_role_fit(p_cts_result jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $function$
-- Sales-profile fit per role, from one stored CTS report (hiring_candidates.cts_result).
--
-- DESIGN RECORD (Peter 2026-09-26):
--   * Ignores the vendor's headline totals (the combined CTS+LSS figure is not
--     even stored; the CTS-only score is shown on the panel but not used here).
--   * Each role = unit-weighted mean of the task scores listed for it in
--     hiregauge_cts_role_weights, rounded to a whole number. Research basis is
--     on that table's comment.
--   * A role whose listed task scores are not all present returns fit null.
--     No per-candidate renormalising - same fail-loud rule as
--     resume_weighted_composite.
--   * The vendor's own trust checks gate everything: Reliability low or
--     Response Distortion high means the vendor says do not use the results,
--     so no fit is returned at all. Moderate (or missing) on either sets
--     check_in_interview - the vendor says cross-check in interviews and
--     references.
--   * The learning-style quiz (LSS) is left out on purpose: it measures
--     reasoning, which the Newtworks assessment already measures, and it moves
--     every role the same way so it cannot tell roles apart.
--   * Separate from the Newtworks assessment. It never feeds any assessment
--     score, verdict or best-fit column, and nothing stores its output.
DECLARE
  v_rel  text := lower(p_cts_result->>'reliability');
  v_rd   text := lower(p_cts_result->>'response_distortion');
  v_fits jsonb;
BEGIN
  IF p_cts_result IS NULL OR jsonb_typeof(p_cts_result) <> 'object' THEN
    RETURN NULL;
  END IF;

  IF v_rel = 'low' OR v_rd = 'high' THEN
    RETURN jsonb_build_object(
      'usable', false,
      'reason', CASE WHEN v_rel = 'low'
                     THEN 'Reliability came back low. The vendor says not to use these results.'
                     ELSE 'Response distortion came back high. The vendor says not to use these results.' END,
      'check_in_interview', false,
      'best_role', NULL,
      'best_fit', NULL,
      'fits', '[]'::jsonb);
  END IF;

  WITH per_role AS (
    SELECT w.role_category AS role,
           CASE WHEN bool_and(jsonb_typeof(p_cts_result->'sales_competencies'->w.competency_key) = 'number')
                THEN round(sum(w.weight * (p_cts_result->'sales_competencies'->>w.competency_key)::numeric)
                           / sum(w.weight))::int
           END AS fit
    FROM public.hiregauge_cts_role_weights w
    WHERE w.weight > 0
    GROUP BY w.role_category
  )
  SELECT jsonb_agg(jsonb_build_object('role', role, 'fit', fit) ORDER BY fit DESC NULLS LAST, role)
  INTO v_fits
  FROM per_role;

  RETURN jsonb_build_object(
    'usable', true,
    'reason', NULL,
    'check_in_interview', (v_rel IS DISTINCT FROM 'high' OR v_rd IS DISTINCT FROM 'low'),
    'best_role', CASE WHEN (v_fits->0->>'fit') IS NOT NULL THEN v_fits->0->>'role' END,
    'best_fit', CASE WHEN (v_fits->0->>'fit') IS NOT NULL THEN (v_fits->0->>'fit')::int END,
    'fits', COALESCE(v_fits, '[]'::jsonb));
END;
$function$;

COMMENT ON FUNCTION public.cts_role_fit(jsonb) IS
'Sales-profile (CTS) fit per role plus best fit, computed on demand from hiring_candidates.cts_result. Separate from the Newtworks assessment: reads no assessment data, writes nothing, feeds no verdict. Weights in hiregauge_cts_role_weights. Called by the candidate page (src/components/CtsResultPanel.jsx).';

GRANT EXECUTE ON FUNCTION public.cts_role_fit(jsonb) TO authenticated;
