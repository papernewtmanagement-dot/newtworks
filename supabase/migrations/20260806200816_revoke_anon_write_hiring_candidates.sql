-- Reverts migration 20260806190242 (hiring_candidates_write_policy_add_anon).
-- That migration granted INSERT/UPDATE/DELETE on hiring_candidates to anon and
-- extended the write RLS policy to anon, on the belief that "the app runs on the
-- plain anon key with no login" and drag-and-drop would otherwise break.
--
-- That premise was wrong. NewtworksApp.jsx has a full Supabase Auth login gate
-- (email/password + magic link + recovery). Its own design comment states:
-- "Data reads still use anon grants underneath... Being logged in (authenticated
-- role) is what unlocks writes such as the staff edit form." Drag-and-drop runs
-- inside the auth gate, so its UPDATE carries the authenticated role. The public
-- candidate assessment route writes via an edge function (fetch to V1_ENDPOINT),
-- not direct table writes. No code path performs an anon write to this table.
--
-- Leaving the grant in place meant anyone holding the public anon key (shipped
-- in the JS bundle) could insert/update/delete candidate PII. Closing it.
--
-- The anon READ grant and the anon-extended SELECT policy are intentionally
-- KEPT — they match the documented design (no blank-screen risk pre-session).
REVOKE INSERT, UPDATE, DELETE ON public.hiring_candidates FROM anon;

ALTER POLICY team_hiring_candidates_auth_write ON public.hiring_candidates
  TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
