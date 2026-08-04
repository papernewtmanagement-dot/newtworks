-- ═════════════════════════════════════════════════════════════════════════════
-- Take function access away from signed-out visitors.
-- ═════════════════════════════════════════════════════════════════════════════
-- 117 database functions in this project run with owner rights, meaning they
-- skip every row rule. 109 of them could be called by a signed-out visitor
-- holding the public browser key, 53 of those change data, and 45 had no
-- authorisation test of any kind. Among them: the four ledger writers, the
-- automation runner, every outbound email and Telegram sender, the pay
-- recompute functions, and the one that sets a teammate's time-clock code.
--
-- Verified before running this: neither signed-out surface calls a database
-- function at all. api/careers.js only reads two tables. CandidateAssessment.jsx
-- only calls the v1-assessment edge function. So signed-out visitors need no
-- function access whatsoever.
--
-- Approach: strip PUBLIC and the signed-out role, then re-grant to signed-in
-- and service role. That closes the outside hole without changing what a
-- signed-in person can reach, so nothing in the app breaks. Restricting
-- individual functions further to admins only is a separate, targeted pass —
-- doing it by privilege here would risk breaking helper calls nested inside
-- caller-rights functions.
--
-- Trigger functions are deliberately left alone. Their privileges are checked
-- when the trigger is created, not when it fires, and the public careers apply
-- form inserts a row that fires triggers — revoking here could break it for no
-- security gain, since a trigger function called directly errors out anyway.
--
-- Extension-owned functions are skipped: they belong to pg_net, http, pgcrypto
-- and friends, and re-granting them is not ours to manage.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TEMP TABLE _fn_locked (routine text, was_callable_signed_out boolean);

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid,
           p.oid::regprocedure::text AS sig,
           has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_had_it
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prorettype::regtype::text <> 'trigger'
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.objid = p.oid AND d.deptype = 'e'
      )
    ORDER BY p.oid::regprocedure::text
  LOOP
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM PUBLIC', r.sig);
    EXECUTE format('REVOKE ALL ON ROUTINE %s FROM anon', r.sig);
    EXECUTE format('GRANT EXECUTE ON ROUTINE %s TO authenticated, service_role', r.sig);
    INSERT INTO _fn_locked VALUES (r.sig, r.anon_had_it);
  END LOOP;
END $$;
