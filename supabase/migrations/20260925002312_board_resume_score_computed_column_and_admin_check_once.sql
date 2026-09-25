-- Hiring board "R" badge: read the resume score straight off the candidate row.
-- Exposed through the API as a computed column: hiring_candidates?select=id,res_composite
-- One function per job: this only forwards to resume_weighted_composite.
-- WHY: the board used to read res_composite from v_hiring_candidates. That view joins
-- verdict_assessment and verdict_interview for every row, and Postgres cannot skip those
-- joins even when only res_composite is selected. On 2026-09-24 that ran the full
-- assessment and interview scoring for 524 candidates, passed the 8s statement limit
-- (error 57014), and left every R badge blank.
CREATE OR REPLACE FUNCTION public.res_composite(hc public.hiring_candidates)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT public.resume_weighted_composite(hc.resume_analysis);
$$;

COMMENT ON FUNCTION public.res_composite(public.hiring_candidates) IS
'API computed column for the hiring board R badge. Forwards to resume_weighted_composite. Board pass 2 reads hiring_candidates?select=id,res_composite. Do not point the board back at v_hiring_candidates for this: that view runs the assessment and interview scoring for every row (timed out 2026-09-24).';

GRANT EXECUTE ON FUNCTION public.res_composite(public.hiring_candidates) TO authenticated;

-- Row rules on hiring_candidates: run the admin check once per query instead of once per row.
-- Same meaning (is_agency_admin takes no arguments, so its answer cannot differ by row).
-- Measured 2026-09-25: the per-row check cost about 1 second on every 524-row board load.
ALTER POLICY hiring_candidates_admin_read ON public.hiring_candidates
  USING ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND (SELECT public.is_agency_admin()));
ALTER POLICY staff_hiring_candidates_select ON public.hiring_candidates
  USING ((SELECT public.is_agency_admin()));
ALTER POLICY hiring_candidates_auth_delete ON public.hiring_candidates
  USING ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND (SELECT public.is_agency_admin()));
ALTER POLICY hiring_candidates_auth_insert ON public.hiring_candidates
  WITH CHECK ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND (SELECT public.is_agency_admin()));
ALTER POLICY hiring_candidates_auth_update ON public.hiring_candidates
  USING ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND (SELECT public.is_agency_admin()))
  WITH CHECK ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND (SELECT public.is_agency_admin()));

NOTIFY pgrst, 'reload schema';
