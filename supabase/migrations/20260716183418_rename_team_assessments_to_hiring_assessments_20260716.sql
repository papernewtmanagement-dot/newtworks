
-- Rename team_assessments → hiring_assessments to reflect actual purpose
-- (hiring-pipeline records including ~30 candidates who never joined the team)

-- Step 1: rename
ALTER TABLE public.team_assessments RENAME TO hiring_assessments;

-- Step 2: rewrite the 12 functions whose source text still says team_assessments
-- (pg_proc.prosrc is text; rename doesn't rewrite it. Fetch each def, substitute, re-create.)
DO $migration$
DECLARE
  r RECORD;
  new_def TEXT;
BEGIN
  FOR r IN
    SELECT oid, proname, pg_get_functiondef(oid) AS def
    FROM pg_proc 
    WHERE prosrc ILIKE '%team_assessments%'
      AND pronamespace = 'public'::regnamespace
  LOOP
    new_def := REPLACE(r.def, 'team_assessments', 'hiring_assessments');
    BEGIN
      EXECUTE new_def;
      RAISE NOTICE 'Rewrote %', r.proname;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Failed to rewrite %: % / %', r.proname, SQLERRM, SQLSTATE;
    END;
  END LOOP;
END
$migration$;
;
