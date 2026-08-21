-- When an auth.users row is created (e.g. by inviteUserByEmail), find the matching
-- public.users row by email and populate auth_user_id + bump invite_status.
-- Idempotent: skips rows already linked.
CREATE OR REPLACE FUNCTION public.link_auth_user_to_public_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE public.users
  SET auth_user_id = NEW.id,
      invited_at = COALESCE(invited_at, NOW()),
      invite_status = CASE
        WHEN invite_status = 'not_invited' THEN 'invited'
        ELSE invite_status
      END,
      updated_at = NOW()
  WHERE auth_user_id IS NULL
    AND lower(email) = lower(NEW.email);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS auth_user_created_link_public ON auth.users;
CREATE TRIGGER auth_user_created_link_public
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.link_auth_user_to_public_user();
