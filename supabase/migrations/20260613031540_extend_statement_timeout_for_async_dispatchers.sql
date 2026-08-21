
-- Service role uses the default authenticator timeout (8s), which trips the
-- 90-second pg_net response wait inside _dispatch_and_wait. Raise it to 180s
-- which gives the dispatcher its 90s window plus headroom. This only affects
-- service_role (used by Edge Functions and admin tools); end-user app traffic
-- (anon, authenticated) keeps its 3s/8s limits.

ALTER ROLE service_role SET statement_timeout = '180s';

-- Belt + suspenders: bake the timeout into the dispatch functions themselves
-- so any future role-config drift can't re-trip this bug.
ALTER FUNCTION public._dispatch_and_wait(uuid, text, jsonb, text, int)
  SET statement_timeout = '180s';

ALTER FUNCTION public.dispatch_email_archiver(uuid, uuid)
  SET statement_timeout = '180s';

ALTER FUNCTION public.dispatch_document_processor(uuid, uuid)
  SET statement_timeout = '180s';

