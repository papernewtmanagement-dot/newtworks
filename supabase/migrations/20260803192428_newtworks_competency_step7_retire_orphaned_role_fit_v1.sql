-- Step 7 (partial) of Newtworks competency layer rebuild -- retire the 7 orphaned
-- assessment_role_fit_<role> functions. Confirmed via two independent audits
-- (pg_depend + text-grep of every function body in the DB) that nothing calls
-- these -- Step 6 rewired assessment_best_fit_role onto the new gated
-- newtworks_role_fit_<role> functions, cutting the last live link. Frontend
-- grep (CandidateDetail.jsx) also confirms no direct RPC call. Dropping is safe.
DROP FUNCTION IF EXISTS public.assessment_role_fit_sales_outbound(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_sales_inbound(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_sales_in_book(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_retention_reception(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_retention_escalation(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_retention_support(uuid);
DROP FUNCTION IF EXISTS public.assessment_role_fit_aspirant(uuid);
