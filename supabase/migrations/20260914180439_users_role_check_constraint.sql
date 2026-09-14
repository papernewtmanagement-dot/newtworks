-- Locks public.users.role to the five tiers the app actually understands.
-- Peter 2026-09-14: the column had no constraint, so any string could land in
-- it. A typo fails safe (NewtworksApp.jsx defaults an unknown role to staff),
-- but a hand-typed 'manager' on the wrong row silently hands over the whole
-- Financials module and every admin manual page, with nothing to catch it.
-- These five values are the ones used by NAV_ITEMS in NewtworksApp.jsx and by
-- is_agency_admin() in the database. Column is NOT NULL, so no null branch.
-- Values in use at the time of writing: owner, manager, staff.
-- NOTE: this constrains the SET of allowed values only. It does not stop a
-- valid value being written to the wrong person — that is still a manual act.

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;

ALTER TABLE public.users ADD CONSTRAINT users_role_check
  CHECK (role = ANY (ARRAY[
    'owner'::text,
    'manager'::text,
    'staff'::text,
    'readonly'::text,
    'accountant'::text
  ]));
