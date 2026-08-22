-- Unblock Cassie immediately.
UPDATE public.users
SET invite_status = 'active',
    last_login = COALESCE(last_login, NOW()),
    updated_at = NOW()
WHERE auth_user_id = 'fa9bf553-74c7-476b-866e-049644dad5a5'
  AND invite_status = 'invited';

-- Server-side invite_status sync. Closes the JWT-rotation race in supabase-js
-- where SetPasswordScreen's client-side .update("users") fired before the
-- newly-rotated JWT was wired into the next PostgREST request, silently
-- hitting RLS as anon and affecting 0 rows. This trigger fires inside the
-- auth.users update transaction (when email_confirmed_at is set), so the
-- flip is atomic with the password confirmation. Works for invite, recovery,
-- and signup flows alike; SetPasswordScreen's redundant client write is
-- harmless if it succeeds and ignored if it doesn't.
CREATE OR REPLACE FUNCTION public.sync_invite_status_on_email_confirm()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only act when email_confirmed_at transitions from NULL to a value.
  IF NEW.email_confirmed_at IS NOT NULL
     AND OLD.email_confirmed_at IS NULL
  THEN
    UPDATE public.users
    SET invite_status = 'active',
        last_login    = COALESCE(last_login, NOW()),
        updated_at    = NOW()
    WHERE auth_user_id = NEW.id
      AND invite_status = 'invited';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_email_confirmed_sync_invite_status ON auth.users;

CREATE TRIGGER on_email_confirmed_sync_invite_status
AFTER UPDATE OF email_confirmed_at ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.sync_invite_status_on_email_confirm();

-- Grant execute to the trigger owner role (postgres) and the auth schema
-- mover role. SECURITY DEFINER means it runs as the function owner, so RLS
-- on public.users is bypassed inside the function — correct behavior here.
