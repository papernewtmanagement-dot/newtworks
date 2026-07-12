-- time_off_requests had INSERT/SELECT/UPDATE policies but no DELETE policy.
-- With RLS enabled, missing DELETE policy → all deletes silently return zero rows.
-- Add DELETE policy matching the UPDATE policy shape: self (requester) OR owner, agency-scoped.

CREATE POLICY "requests_delete_self_or_owner"
ON public.time_off_requests
FOR DELETE
TO authenticated
USING (
  agency_id IN (
    SELECT u.agency_id FROM users u WHERE u.auth_user_id = auth.uid()
  )
  AND (
    requester_team_id IN (
      SELECT u.team_member_id FROM users u WHERE u.auth_user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.auth_user_id = auth.uid() AND u.role = 'owner'
    )
  )
);
