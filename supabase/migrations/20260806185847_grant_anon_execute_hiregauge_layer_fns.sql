-- v_hiring_candidates (queried by the anon-key frontend, no login) calls these
-- functions via plain calls and a LEFT JOIN LATERAL. The retire_old_cts_assessment_path
-- migrations (2026-08-06) recreated several of them and granted EXECUTE to
-- authenticated only, never to anon. Every anon query against the view failed
-- with "permission denied for function ..." as a result — this is why the
-- Growth tab kanban board stayed blank even after the select-list fix.
GRANT EXECUTE ON FUNCTION public.resume_capability(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.resume_character(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.resume_commitment(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.assessment_capability(uuid, text) TO anon;
GRANT EXECUTE ON FUNCTION public.assessment_character(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.assessment_commitment(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.interview_capability(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.interview_character(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.interview_commitment(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public._assessment_character_parts(uuid) TO anon;
