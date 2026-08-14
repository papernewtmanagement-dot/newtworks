-- Restore security_invoker on v_hiring_candidates.
-- The 2026-08-13 morning fix (ALTER VIEW ... SET security_invoker = true, applied ad hoc,
-- mirrored to repo as 20260813150000 but never entered in schema_migrations) was silently
-- undone the same day by the DROP+CREATE view recreations in 20260813214926 /
-- 20260813215358 / 20260813223315, which reset reloptions to defaults. Without this flag
-- the view runs owner-rights and bypasses the admin-only RLS on hiring_candidates,
-- exposing candidate PII to any authenticated non-admin login.
-- Perf prerequisite already in place: assessment_capability / assessment_character /
-- assessment_commitment / _newtworks_protocol_validity are SECURITY DEFINER
-- (20260813224026), so the invoker-rights view does not re-trip the RLS-per-reference
-- statement timeout.
ALTER VIEW public.v_hiring_candidates SET (security_invoker = true);

-- Tighten the default grants the recreate re-applied. The view is read-only by design.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_hiring_candidates FROM authenticated;
REVOKE ALL ON public.v_hiring_candidates FROM anon;
