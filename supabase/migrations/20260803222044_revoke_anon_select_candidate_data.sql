REVOKE SELECT ON public.hiregauge_candidate_responses FROM anon;
REVOKE SELECT ON public.hiring_candidates FROM anon;

DROP POLICY IF EXISTS staff_hiring_candidates_select ON public.hiring_candidates;
CREATE POLICY staff_hiring_candidates_select
  ON public.hiring_candidates FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS responses_agency ON public.hiregauge_candidate_responses;
CREATE POLICY responses_agency
  ON public.hiregauge_candidate_responses FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365')
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365');
