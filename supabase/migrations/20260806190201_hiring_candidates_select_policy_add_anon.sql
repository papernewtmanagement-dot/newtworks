-- Root cause of the blank Growth-tab kanban board, found by tracing the actual
-- error chain (not guessed): staff_hiring_candidates_select ("true" USING clause,
-- correctly permissive) was scoped TO authenticated only. anon was never covered.
-- This is a pre-existing gap, not something today's migrations broke directly —
-- it was masked until now because the functions the view calls (resume_capability,
-- assessment_capability, assessment_best_fit_role, etc.) used to be SECURITY DEFINER
-- and bypassed RLS. Today's retire_old_cts_assessment_path migrations recreated
-- several of them as plain (invoker-rights) functions, which made them subject to
-- RLS as the anon role for the first time — and the Newtworks frontend runs on the
-- plain anon key with no login, so every query hit this wall.
--
-- The write policy (team_hiring_candidates_auth_write) is intentionally left
-- authenticated-only — this migration only extends the READ policy.
ALTER POLICY staff_hiring_candidates_select ON public.hiring_candidates
  TO authenticated, anon
  USING (true);
