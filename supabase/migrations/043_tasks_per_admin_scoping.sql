-- 043: per-admin task scoping
-- Owner (Peter) sees all tasks in agency; can assign to any admin.
-- Manager (Marie) sees only tasks where assigned_to = her users.id.
-- Staff: no read/write (RLS denies, plus Tasks module is admin-only).
-- Backfill: all 305 pre-existing tasks (all assigned_to NULL) -> Peter.

-- 1) Backfill existing tasks to Peter
UPDATE public.tasks
SET assigned_to = '6f0fa5c3-1bb9-4e96-8e6f-33705c89aa95'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND assigned_to IS NULL;

-- 2) FK to public.users(id), nullable, ON DELETE SET NULL
DO $$ BEGIN
  ALTER TABLE public.tasks
    ADD CONSTRAINT tasks_assigned_to_users_fk
    FOREIGN KEY (assigned_to)
    REFERENCES public.users(id)
    ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- 3) Replace over-broad RLS with role-aware policies
DROP POLICY IF EXISTS anon_read_tasks ON public.tasks;
DROP POLICY IF EXISTS authenticated_insert_tasks ON public.tasks;
DROP POLICY IF EXISTS authenticated_update_tasks ON public.tasks;
DROP POLICY IF EXISTS authenticated_delete_tasks ON public.tasks;

-- Owner: full read/write on agency tasks
CREATE POLICY tasks_owner_full ON public.tasks
  FOR ALL TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = 'owner'
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = 'owner'
    )
  );

-- Manager: read/write only tasks assigned to themselves
CREATE POLICY tasks_manager_own ON public.tasks
  FOR ALL TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = 'manager'
        AND u.id = public.tasks.assigned_to
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role = 'manager'
        AND u.id = public.tasks.assigned_to
    )
  );

-- Note: anon role + staff get no policy = no access (RLS default deny).
-- Service role bypasses RLS, so automation writers still work.
