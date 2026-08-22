-- Close anonymous EXECUTE on every remaining function in the public schema.
--
-- Anyone with the project URL and the public key could call these while logged
-- out. 21 of the 49 are SECURITY DEFINER, meaning they also skip row security --
-- those include the Amazon categorisers, the cash-register coding-rule applier,
-- the statement reconciliation check, the not-on-statement alerter and the
-- hiring scoring-cache refreshers.
--
-- Safe because every one of the 49 was verified first to already hold an
-- explicit service_role grant (0 missing), and the browser-facing ones also hold
-- an explicit authenticated grant. REVOKE ... FROM PUBLIC does not touch
-- role-specific grants, so:
--   bots / cron / edge functions  -> service_role, unaffected
--   Peter and Marie in the app    -> authenticated, unaffected
--   anonymous visitors            -> closed
--
-- The two assessment-token functions held back last pass are INCLUDED now.
-- Checked directly rather than guessed: src/modules/CandidateAssessment.jsx
-- states it deliberately does not import the browser database client, and
-- reaches everything through the v1-assessment edge function as the sole
-- gateway (callV1 -> actions verify / serve / save_response / finalize). The
-- edge function runs as service_role, so a logged-out candidate never calls
-- compute_v1_assessment_token or verify_v1_assessment_token from the browser.
-- Candidate links are unaffected.
--
-- Detection note: the correct test for a PUBLIC grant is aclexplode with
-- grantee = 0. A text match on proacl for '=X/' is WRONG -- it also matches
-- 'authenticated=X/postgres' and 'service_role=X/postgres'.

DO $$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
    WHERE ns.nspname = 'public'
      AND p.prokind = 'f'
      AND EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                  WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')
      -- belt and braces: never strip PUBLIC from something that would be
      -- left with no way in at all
      AND EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                  JOIN pg_roles ro ON ro.oid = a.grantee
                  WHERE ro.rolname IN ('service_role','authenticated')
                    AND a.privilege_type = 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Revoked anonymous EXECUTE on % functions', n;
END $$;
