ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS wtw_requirements_adjustment_quotes integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS wtw_requirements_adjustment numeric NOT NULL DEFAULT 0;

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS wtw_requirements_adjustment_quotes integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS wtw_requirements_adjustment numeric NOT NULL DEFAULT 0;
