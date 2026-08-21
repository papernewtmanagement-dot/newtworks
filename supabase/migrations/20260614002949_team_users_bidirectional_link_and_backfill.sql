-- 1. Reverse pointer on team
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS user_id uuid
    REFERENCES public.users(id) ON DELETE SET NULL;

-- Index it so lookups stay fast even as the agency grows
CREATE INDEX IF NOT EXISTS team_user_id_idx ON public.team(user_id);
CREATE INDEX IF NOT EXISTS users_team_member_id_idx ON public.users(team_member_id);

-- 2. Sync trigger.  users.team_member_id is authoritative; team.user_id mirrors it.
-- Whenever a users row's team_member_id changes (or the row is deleted), we
-- clear the old team.user_id and set the new one.  Editing team.user_id directly
-- is allowed but not recommended; use users.team_member_id as the canonical edit.
CREATE OR REPLACE FUNCTION public.sync_team_user_link()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- On UPDATE: if team_member_id changed, clear the old team row's pointer
  IF TG_OP = 'UPDATE'
     AND OLD.team_member_id IS NOT NULL
     AND OLD.team_member_id IS DISTINCT FROM NEW.team_member_id THEN
    UPDATE public.team SET user_id = NULL
    WHERE id = OLD.team_member_id AND user_id = OLD.id;
  END IF;

  -- On DELETE: clear the linked team row
  IF TG_OP = 'DELETE' AND OLD.team_member_id IS NOT NULL THEN
    UPDATE public.team SET user_id = NULL
    WHERE id = OLD.team_member_id AND user_id = OLD.id;
    RETURN OLD;
  END IF;

  -- On INSERT or UPDATE where team_member_id is set: write the mirror
  IF TG_OP IN ('INSERT','UPDATE') AND NEW.team_member_id IS NOT NULL THEN
    UPDATE public.team SET user_id = NEW.id
    WHERE id = NEW.team_member_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_sync_team_link ON public.users;
CREATE TRIGGER users_sync_team_link
AFTER INSERT OR UPDATE OF team_member_id OR DELETE ON public.users
FOR EACH ROW EXECUTE FUNCTION public.sync_team_user_link();

-- 3. Create users rows for active salaried team members who don't have one yet
INSERT INTO public.users (
  agency_id, email, full_name, role, team_member_id,
  allowed_modules, is_active, invite_status
)
SELECT
  t.agency_id,
  t.email_personal,
  t.first_name || ' ' || t.last_name,
  'staff',
  t.id,
  NULL,                       -- Peter will scope per-user later
  true,
  'not_invited'
FROM team t
LEFT JOIN users u ON u.team_member_id = t.id OR lower(u.email) = lower(t.email_personal)
WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND t.is_active = true
  AND t.is_test_user = false
  AND t.email_personal IS NOT NULL
  AND u.id IS NULL;

-- 4. Link Peter's existing users row (paper.newt.management@gmail.com) to his team row
UPDATE public.users
SET team_member_id = (
  SELECT id FROM team
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND first_name = 'Peter' AND last_name = 'Story'
  LIMIT 1
)
WHERE id = '6f0fa5c3-1bb9-4e96-8e6f-33705c89aa95'   -- Peter's existing user id
  AND team_member_id IS NULL;

-- 5. Belt-and-suspenders: backfill any team.user_id that didn't get caught by the trigger
UPDATE public.team t
SET user_id = u.id
FROM public.users u
WHERE u.team_member_id = t.id
  AND (t.user_id IS NULL OR t.user_id <> u.id);
