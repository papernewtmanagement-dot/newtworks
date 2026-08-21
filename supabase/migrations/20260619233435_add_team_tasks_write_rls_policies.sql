-- The team and tasks tables had RLS enabled with only a SELECT policy.
-- Result: every frontend INSERT/UPDATE/DELETE was silently denied by RLS,
-- returning no error and zero affected rows. Add write policies that mirror
-- the existing authenticated_*_users pattern so the frontend Edit, terminate,
-- and reactivate flows can actually write to the database.

-- TEAM
CREATE POLICY "authenticated_insert_team" ON public.team
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "authenticated_update_team" ON public.team
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "authenticated_delete_team" ON public.team
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- TASKS
CREATE POLICY "authenticated_insert_tasks" ON public.tasks
  FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "authenticated_update_tasks" ON public.tasks
  FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

CREATE POLICY "authenticated_delete_tasks" ON public.tasks
  FOR DELETE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
