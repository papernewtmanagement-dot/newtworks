-- Two versions of compute_commission_accrual were live: a 5-input original and a
-- 6-input replacement that adds the reserve. Every input past the second has a
-- default, so any normal two-input call failed with "function is not unique".
-- Peter 2026-08-31: delete the old one. Keeps the 6-input version only.
DROP FUNCTION IF EXISTS public.compute_commission_accrual(uuid, date, numeric, numeric, numeric);
