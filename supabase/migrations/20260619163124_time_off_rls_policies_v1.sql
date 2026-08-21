-- Time Off RLS policies — first cut. RLS was enabled on all three tables when
-- the time-off schema landed (2026-06-18) but no policies were ever added, so
-- every UI insert/update has been denied. Adding agency-scoped policies for
-- the three tables here. Dispatcher functions run as the postgres role via
-- pg_cron, which bypasses RLS, so they are not affected.

-- =========================================================================
-- time_off_requests
-- =========================================================================
CREATE POLICY "requests_read_agency"
ON public.time_off_requests
FOR SELECT
TO authenticated
USING (
  agency_id IN (
    SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
);

CREATE POLICY "requests_insert_own"
ON public.time_off_requests
FOR INSERT
TO authenticated
WITH CHECK (
  agency_id IN (
    SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
  AND requester_team_id IN (
    SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
);

-- Requester can update their own (cancel); owner can update any (approve/deny).
CREATE POLICY "requests_update_self_or_owner"
ON public.time_off_requests
FOR UPDATE
TO authenticated
USING (
  agency_id IN (
    SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
  AND (
    requester_team_id IN (
      SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()
    )
    OR EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid() AND u.role = 'owner'
    )
  )
)
WITH CHECK (
  agency_id IN (
    SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
);

-- =========================================================================
-- time_off_votes
-- =========================================================================
CREATE POLICY "votes_read_agency"
ON public.time_off_votes
FOR SELECT
TO authenticated
USING (
  request_id IN (
    SELECT r.id FROM public.time_off_requests r
    WHERE r.agency_id IN (
      SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()
    )
  )
);

CREATE POLICY "votes_insert_own"
ON public.time_off_votes
FOR INSERT
TO authenticated
WITH CHECK (
  voter_team_id IN (
    SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
  AND request_id IN (
    SELECT r.id FROM public.time_off_requests r
    WHERE r.agency_id IN (
      SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()
    )
  )
);

CREATE POLICY "votes_update_own"
ON public.time_off_votes
FOR UPDATE
TO authenticated
USING (
  voter_team_id IN (
    SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
)
WITH CHECK (
  voter_team_id IN (
    SELECT u.team_member_id FROM public.users u WHERE u.auth_user_id = auth.uid()
  )
);

-- =========================================================================
-- time_off_notification_log (owner-only diagnostic table)
-- =========================================================================
CREATE POLICY "notification_log_read_owner"
ON public.time_off_notification_log
FOR SELECT
TO authenticated
USING (
  agency_id IN (
    SELECT u.agency_id FROM public.users u
    WHERE u.auth_user_id = auth.uid() AND u.role = 'owner'
  )
);
