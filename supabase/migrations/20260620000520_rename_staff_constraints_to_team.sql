-- Cosmetic rename: bring legacy staff_* CHECK constraint names in line with
-- the renamed table (team). No functional change; same constraint expressions.
ALTER TABLE public.team RENAME CONSTRAINT staff_category_check            TO team_category_check;
ALTER TABLE public.team RENAME CONSTRAINT staff_complacency_risk_check    TO team_complacency_risk_check;
ALTER TABLE public.team RENAME CONSTRAINT staff_performance_status_check  TO team_performance_status_check;
ALTER TABLE public.team RENAME CONSTRAINT staff_primary_function_check    TO team_primary_function_check;
ALTER TABLE public.team RENAME CONSTRAINT staff_role_fit_score_check      TO team_role_fit_score_check;
ALTER TABLE public.team RENAME CONSTRAINT staff_secondary_function_check  TO team_secondary_function_check;
