-- Peter 2026-09-19: a verified entry that is later changed has to go back into
-- the spot-check, because what he approved is not what is on file any more.
--
-- The check is on the whole row rather than a list of fields, minus the
-- bookkeeping ones, so a column added later is covered without anyone
-- remembering to come back here. Verifying itself, and a spot-check note,
-- do not count as a change.

CREATE OR REPLACE FUNCTION public.retention_activity_unverify_on_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE skip text[] := ARRAY['verified_at', 'verified_by', 'updated_at', 'spot_check_note'];
BEGIN
  IF NEW.verified_at IS NULL THEN RETURN NEW; END IF;
  IF (to_jsonb(NEW) - skip) IS DISTINCT FROM (to_jsonb(OLD) - skip) THEN
    NEW.verified_at := NULL;
    NEW.verified_by := NULL;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS retention_activity_unverify_on_change ON public.retention_activity_log;
CREATE TRIGGER retention_activity_unverify_on_change
BEFORE UPDATE ON public.retention_activity_log
FOR EACH ROW EXECUTE FUNCTION public.retention_activity_unverify_on_change();
