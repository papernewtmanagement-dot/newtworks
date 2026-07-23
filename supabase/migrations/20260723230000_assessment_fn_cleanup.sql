-- Assessment fn cleanup 2026-07-23:
-- 1) drop dead helper _resume_reformat_add_separators (0 callers verified)
-- 2) rename 7 role-fit diagnostic wrappers cts_role_fit_* -> assessment_role_fit_*
--    (0 callers, safe rename; brings prefix in line with the assessment layer)

DROP FUNCTION IF EXISTS public._resume_reformat_add_separators(text);

ALTER FUNCTION public.cts_role_fit_sales_outbound(uuid)       RENAME TO assessment_role_fit_sales_outbound;
ALTER FUNCTION public.cts_role_fit_sales_inbound(uuid)        RENAME TO assessment_role_fit_sales_inbound;
ALTER FUNCTION public.cts_role_fit_sales_in_book(uuid)        RENAME TO assessment_role_fit_sales_in_book;
ALTER FUNCTION public.cts_role_fit_retention_reception(uuid)  RENAME TO assessment_role_fit_retention_reception;
ALTER FUNCTION public.cts_role_fit_retention_escalation(uuid) RENAME TO assessment_role_fit_retention_escalation;
ALTER FUNCTION public.cts_role_fit_retention_support(uuid)    RENAME TO assessment_role_fit_retention_support;
ALTER FUNCTION public.cts_role_fit_aspirant(uuid)             RENAME TO assessment_role_fit_aspirant;
