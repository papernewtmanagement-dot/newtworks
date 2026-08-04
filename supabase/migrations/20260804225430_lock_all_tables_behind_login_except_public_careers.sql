-- ═════════════════════════════════════════════════════════════════════════════
-- Lock every table behind the login. Standing directive, not previously enforced.
-- ═════════════════════════════════════════════════════════════════════════════
-- 110+ row rules granted access to the signed-out visitor role, most of them
-- "allow everything". The public browser key ships inside the site, so anybody
-- who viewed the page source could read payroll, bank and card transactions,
-- the general ledger, compensation recaps, the team roster with personal email
-- addresses, behavioural notes on staff, hiring records, and the operating
-- notes tables — all without signing in. Three tables were also writable by
-- signed-out visitors.
--
-- This flips every one of those rules to signed-in access only, leaving the
-- rules themselves byte-identical otherwise. ALTER POLICY is used rather than
-- drop-and-recreate so no expression can drift.
--
-- KEPT PUBLIC ON PURPOSE (the public careers site depends on them):
--   job_postings.jp_public_active            read, already narrowed to active +
--                                            published-to-careers-page rows only
--   job_screener_questions.jsq_public_active read, already narrowed to active
--   job_applications.ja_anon_insert          insert only, no read — this is how
--                                            an outside applicant submits a form
--
-- The public candidate assessment needs NO table access: CandidateAssessment.jsx
-- talks only to the v1-assessment edge function, which holds its own privileged
-- key. Verified before running this.
-- ═════════════════════════════════════════════════════════════════════════════

CREATE TEMP TABLE _locked_down (table_name text, policy_name text, command text);

DO $$
DECLARE
  r record;
  v_keep text[] := ARRAY['jp_public_active', 'jsq_public_active', 'ja_anon_insert'];
BEGIN
  FOR r IN
    SELECT c.relname AS tbl, p.polname, p.polcmd
    FROM pg_policy p
    JOIN pg_class c     ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND NOT (p.polname = ANY(v_keep))
      AND (
        -- granted to PUBLIC (role list of {0}), which includes signed-out visitors
        0 = ANY(p.polroles)
        -- or granted to the signed-out visitor role by name
        OR EXISTS (
          SELECT 1 FROM pg_roles rr
          WHERE rr.oid = ANY(p.polroles) AND rr.rolname = 'anon'
        )
      )
    ORDER BY c.relname, p.polname
  LOOP
    EXECUTE format('ALTER POLICY %I ON public.%I TO authenticated', r.polname, r.tbl);
    INSERT INTO _locked_down VALUES (
      r.tbl,
      r.polname,
      CASE r.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT'
                    WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE'
                    ELSE 'ALL' END
    );
  END LOOP;
END $$;
