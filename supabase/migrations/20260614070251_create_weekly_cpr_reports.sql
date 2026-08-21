
-- ============================================================
-- Weekly CPR (Compliance, Production, Retention) reports
-- One row per week, agency-level. Per-team-member detail in child table.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.weekly_cpr_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  week_ending_date date NOT NULL,
  
  -- AUTO retention block (image 2)
  auto_ratio_pct numeric(6,2),
  auto_rank integer,
  auto_bonus numeric(12,2),
  
  -- FIRE retention block (image 2)
  fire_ratio_pct numeric(6,2),
  fire_rank integer,
  fire_bonus numeric(12,2),
  
  -- Claims block (image 3)
  non_pays integer DEFAULT 0,
  new_claims integer DEFAULT 0,
  open_claims integer DEFAULT 0,
  unreviewed_claims integer DEFAULT 0,
  
  -- Freeform
  notes text,
  
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(agency_id, week_ending_date)
);

CREATE INDEX IF NOT EXISTS idx_weekly_cpr_reports_week
  ON public.weekly_cpr_reports(agency_id, week_ending_date DESC);

-- ============================================================
-- Per-team-member detail rows for the weekly CPR
-- ============================================================

CREATE TABLE IF NOT EXISTS public.weekly_cpr_team_detail (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  weekly_cpr_report_id uuid NOT NULL REFERENCES public.weekly_cpr_reports(id) ON DELETE CASCADE,
  team_member_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  
  -- Top "Required items" block (image 1, top table)
  carryover integer DEFAULT 0,
  missed integer DEFAULT 0,
  cost integer DEFAULT 0,
  total integer DEFAULT 0,
  paid integer DEFAULT 0,
  owed integer DEFAULT 0,
  
  -- Code Reds / Code Yellows (free text, null if none)
  code_reds text,
  code_yellows text,
  
  -- End-of-day items (image 1, middle: CPR Reply / Wrapup / Inbox)
  cpr_reply_done boolean DEFAULT true,
  wrapup_done boolean DEFAULT true,
  inbox_done boolean DEFAULT true,
  
  -- Daily checklist (image 1, bottom: 11 columns, true=Done, false=Missed)
  shareds_done boolean DEFAULT true,
  texts_done boolean DEFAULT true,
  deposits_done boolean DEFAULT true,
  appts_done boolean DEFAULT true,
  tasks_done boolean DEFAULT true,
  cases_done boolean DEFAULT true,
  no_fu_task_done boolean DEFAULT true,
  new_opps_done boolean DEFAULT true,
  no_onboarding_done boolean DEFAULT true,
  no_phone_done boolean DEFAULT true,
  bad_data_done boolean DEFAULT true,
  
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(weekly_cpr_report_id, team_member_id)
);

CREATE INDEX IF NOT EXISTS idx_weekly_cpr_team_detail_report
  ON public.weekly_cpr_team_detail(weekly_cpr_report_id);

CREATE INDEX IF NOT EXISTS idx_weekly_cpr_team_detail_member
  ON public.weekly_cpr_team_detail(team_member_id);

-- ============================================================
-- updated_at triggers
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_weekly_cpr_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_weekly_cpr_reports_updated_at ON public.weekly_cpr_reports;
CREATE TRIGGER trg_weekly_cpr_reports_updated_at
  BEFORE UPDATE ON public.weekly_cpr_reports
  FOR EACH ROW EXECUTE FUNCTION public.set_weekly_cpr_updated_at();

DROP TRIGGER IF EXISTS trg_weekly_cpr_team_detail_updated_at ON public.weekly_cpr_team_detail;
CREATE TRIGGER trg_weekly_cpr_team_detail_updated_at
  BEFORE UPDATE ON public.weekly_cpr_team_detail
  FOR EACH ROW EXECUTE FUNCTION public.set_weekly_cpr_updated_at();

-- ============================================================
-- RLS + grants (rule #6 — anon role must be covered)
-- ============================================================

ALTER TABLE public.weekly_cpr_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_cpr_team_detail ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS weekly_cpr_reports_all_access ON public.weekly_cpr_reports;
CREATE POLICY weekly_cpr_reports_all_access
  ON public.weekly_cpr_reports
  FOR ALL
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS weekly_cpr_team_detail_all_access ON public.weekly_cpr_team_detail;
CREATE POLICY weekly_cpr_team_detail_all_access
  ON public.weekly_cpr_team_detail
  FOR ALL
  TO anon, authenticated
  USING (true)
  WITH CHECK (true);

GRANT ALL ON public.weekly_cpr_reports TO anon, authenticated;
GRANT ALL ON public.weekly_cpr_team_detail TO anon, authenticated;

COMMENT ON TABLE public.weekly_cpr_reports IS
  'Weekly CPR (Compliance, Production, Retention) — one row per agency per week. Week ends Saturday. Auto/Fire retention ratios + claims summary live here. Per-team-member daily checklist in weekly_cpr_team_detail.';

COMMENT ON TABLE public.weekly_cpr_team_detail IS
  'Per-team-member weekly CPR detail — required items missed (top block), Code Reds/Yellows (free text), and 11-column daily checklist (boolean done=true / missed=false).';

