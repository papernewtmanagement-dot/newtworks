-- Same missing-anon-role pattern as the read policy, one layer over: the Growth
-- tab's drag-and-drop stage change (Team.jsx updateApplicantStage) does a plain
-- .update() through the anon-key client with no login. team_hiring_candidates_auth_write
-- was scoped TO authenticated only, so every stage-change update would fail with
-- "permission denied for table hiring_candidates" — silently, since the frontend
-- only console.errors on write failure and has no user-facing retry. Same USING
-- clause (agency_id match), just extended to the role the app actually runs as.
GRANT INSERT, UPDATE, DELETE ON public.hiring_candidates TO anon;

ALTER POLICY team_hiring_candidates_auth_write ON public.hiring_candidates
  TO authenticated, anon
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
