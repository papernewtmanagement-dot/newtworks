-- Interim Invite User support: allow authenticated role to INSERT placeholder
-- user rows and UPDATE existing rows, scoped to the agency. SELECT already exists.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid = 'public.users'::regclass AND polname = 'authenticated_insert_users'
  ) THEN
    CREATE POLICY authenticated_insert_users ON public.users
      FOR INSERT TO authenticated
      WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policy
    WHERE polrelid = 'public.users'::regclass AND polname = 'authenticated_update_users'
  ) THEN
    CREATE POLICY authenticated_update_users ON public.users
      FOR UPDATE TO authenticated
      USING (agency_id = '126794dd-25ff-47d2-a436-724499733365')
      WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365');
  END IF;
END $$;
