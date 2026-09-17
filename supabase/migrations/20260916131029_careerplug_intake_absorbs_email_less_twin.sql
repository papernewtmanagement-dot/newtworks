-- CareerPlug intake matched an incoming application to an existing candidate on
-- email alone. When the same person arrived down two doors -- a notification
-- carrying no email and a resume mail carrying one -- the email match missed and
-- a second, empty row was minted. 27 of those were deleted by hand on 2026-08-10;
-- that was cleanup, not a fix.
--
-- Matching now tries, in order: the CareerPlug application id (exact, no false
-- merge possible), then email, then an existing row of the same name that has NO
-- email at all. The last one can only ever absorb a stub, so two real people who
-- share a name can never be merged into one. The update also fills in the email
-- it was missing.
--
-- The body is read with pg_get_functiondef and rewritten inside this one
-- transaction, so a concurrent edit cannot be silently overwritten by a stale
-- snapshot. Both replacements are asserted unique before anything is executed.

DO $mig$
DECLARE
  v_def text;
  v_old_where CONSTANT text := 'where agency_id = p_agency_id and lower(email) = v_email';
  v_new_where CONSTANT text :=
    'where agency_id = p_agency_id
        and (
          (v_evt.app_id is not null and careerplug_app_id = v_evt.app_id)
          or (v_email is not null and lower(email) = v_email)
          or (
            email is null
            and (v_app ->> ''firstname'') is not null
            and (v_app ->> ''lastname'') is not null
            and lower(first_name) = lower(v_app ->> ''firstname'')
            and lower(last_name)  = lower(v_app ->> ''lastname'')
          )
        )';
  v_old_upd CONSTANT text := 'last_name   = coalesce(hc.last_name,  v_app ->> ''lastname''),';
  v_new_upd CONSTANT text := 'last_name   = coalesce(hc.last_name,  v_app ->> ''lastname''),
            email       = coalesce(hc.email,      v_app ->> ''email''),';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'ingest_careerplug_applications';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'ingest_careerplug_applications not found';
  END IF;

  IF (length(v_def) - length(replace(v_def, v_old_where, ''))) / length(v_old_where) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one email-match clause, found a different shape';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_old_upd, ''))) / length(v_old_upd) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one last_name update line, found a different shape';
  END IF;

  v_def := replace(v_def, v_old_where, v_new_where);
  v_def := replace(v_def, v_old_upd, v_new_upd);

  EXECUTE v_def;
END
$mig$;
