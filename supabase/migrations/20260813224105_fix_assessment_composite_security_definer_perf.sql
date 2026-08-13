-- Fix: Team Growth Kanban board's pass-2 assessment score query (v_hiring_candidates
-- assessment_composite / protocol_validity_v / protocol_validity_label) has been
-- returning HTTP 500 (statement timeout, code 57014) in production since at least
-- 2026-08-13 18:08, recurring every time the Growth tab loads (confirmed in
-- postgrest_logs and postgres_logs -- "canceling statement due to statement timeout").
--
-- Root cause: migration 20260813150000_v_hiring_candidates_security_invoker.sql
-- correctly flipped the view to SECURITY INVOKER so it respects RLS on
-- hiring_candidates (candidate PII) for the querying user. But that same flip
-- means every nested function call inside assessment_capability / _character /
-- _commitment / _newtworks_protocol_validity now ALSO re-evaluates RLS
-- (is_agency_admin() -> current_app_user_role() -> users table lookup) on every
-- read of the four reference/config tables the scoring engine consults --
-- hiregauge_role_facet_weights, hiregauge_facet_norms, hiregauge_layer_composite_weights,
-- hiregauge_instrument_items -- for every one of 27 inputs x 7 roles, repeated per
-- candidate. Confirmed: as postgres (RLS bypassed) the same query runs in ~0.9s for
-- 31 candidates; as the authenticated app role it blows PostgREST's 8s statement
-- ceiling every time.
--
-- Fix: mark the four functions the view calls DIRECTLY as SECURITY DEFINER (owned
-- by postgres, which bypasses RLS). SECURITY DEFINER changes the effective role for
-- the ENTIRE nested call chain underneath each of these four functions, so every
-- downstream read of the reference/weight/norm tables runs at full speed again --
-- without touching RLS on hiring_candidates itself, which the outer view scan still
-- enforces as the invoking (authenticated) user. This restores the pre-security-invoker
-- performance for the scoring engine while keeping the actual PII-access security fix
-- intact. Reference tables here (weights, norms, item bank) contain no candidate data.
--
-- Verified fixed by simulating a real authenticated session (SET LOCAL ROLE
-- authenticated + request.jwt.claims): 1.28s, well under PostgREST's 8s ceiling.

ALTER FUNCTION public.assessment_capability(uuid, text) SECURITY DEFINER SET search_path = public;
ALTER FUNCTION public.assessment_character(uuid) SECURITY DEFINER SET search_path = public;
ALTER FUNCTION public.assessment_commitment(uuid) SECURITY DEFINER SET search_path = public;
ALTER FUNCTION public._newtworks_protocol_validity(hiring_candidates) SECURITY DEFINER SET search_path = public;
