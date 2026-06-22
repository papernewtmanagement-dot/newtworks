-- 032_drop_users_allowed_modules.sql
-- Drops the now-unused public.users.allowed_modules column.
--
-- Rationale: webapp access is purely role-based (admin tier = owner+manager;
-- team tier = everyone else, sees dashboard/cpr/time/handbook/playbook).
-- Per-user narrowing via allowed_modules was a holdover from a different
-- mental model. Removed 2026-06-22 to eliminate the footgun.
--
-- See operational_rule "BCC webapp default visibility — admin-only (owner+manager)
-- unless Peter authorizes team access" for the access model.

ALTER TABLE public.users DROP COLUMN IF EXISTS allowed_modules;
