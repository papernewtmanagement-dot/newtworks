-- Directory-safe projection of `team`. Everyone signed in can read this —
-- no pay, no benefits, no HR notes, no PIP/termination fields, no PIN hash.
-- team itself stays admin-or-own-row (previous migration). This view runs
-- with the view owner's privileges (no security_invoker), which is
-- deliberate here: it's a controlled, pre-vetted projection meant to be
-- open regardless of the underlying row policy on `team`.
--
-- Column selection is driven by what CPRDetail, Manual, Onboarding,
-- Licensing, PFA, FitScorecards, and TimeOffRequests actually query today.
-- Peter confirmed 2026-08-04: personal phone/email stay visible team-wide
-- (Handbook's existing directory use is correct). Excluded: pay_rate,
-- pay_type, pay_frequency, annual_benefits_value and the two benefit
-- columns, notes, compliance_flag, performance_status, role_fit_score,
-- complacency_risk, termination_review_date, pip_start_date, pip_end_date,
-- termination_reason, final_paycheck_date, time_clock_pin_hash, home
-- address fields, nmls_number/signature_title/credentials_line — none of
-- the 9 team-visible modules need these, and several are exactly the
-- people-decision fields core_principles requires to stay documented but
-- restricted.
CREATE VIEW public.team_directory AS
SELECT
  id, agency_id, first_name, last_name, nickname, role, role_category, role_level,
  category, employment_type, is_active, archived_at, hire_date, start_date,
  work_location, four_day_off_day, phone_extension, phone_personal, email_personal,
  email_sf, sf_alias, account_alpha, license_states, license_pc, license_lh,
  license_ips, primary_function, secondary_function, user_id, is_admin_backoffice,
  is_test_user, photo_storage_path
FROM public.team;

GRANT SELECT ON public.team_directory TO authenticated;

