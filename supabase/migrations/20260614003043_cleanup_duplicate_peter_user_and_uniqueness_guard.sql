-- Remove the duplicate Peter row (the one without auth and with the personal email)
DELETE FROM public.users
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND email = 'storypeterj@gmail.com'
  AND auth_user_id IS NULL;

-- Reassert the correct link for Peter's authoritative user row (the trigger
-- on DELETE may have cleared team.user_id; restore it from the remaining row)
UPDATE public.team t
SET user_id = u.id
FROM public.users u
WHERE u.team_member_id = t.id
  AND (t.user_id IS NULL OR t.user_id <> u.id);

-- Guard rail: only one users row can claim any given team_member_id per agency.
-- Multiple NULL team_member_ids are still allowed (Marie, Rebecca, etc.)
CREATE UNIQUE INDEX IF NOT EXISTS users_one_per_team_member
ON public.users(agency_id, team_member_id)
WHERE team_member_id IS NOT NULL;
