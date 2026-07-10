-- Table: LLM-summarized recent behavioral trajectory per active team member.
-- One row per team_member_id. Refreshed on-demand + weekly automation.
CREATE TABLE IF NOT EXISTS public.team_trajectory_summaries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL UNIQUE,
  summary text NOT NULL,
  notes_analyzed_count int NOT NULL DEFAULT 0,
  notes_range_start date,
  notes_range_end date,
  model_used text,
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

ALTER TABLE public.team_trajectory_summaries ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='team_trajectory_summaries'
      AND policyname='anon_read_team_trajectory_summaries'
  ) THEN
    CREATE POLICY anon_read_team_trajectory_summaries ON public.team_trajectory_summaries
      FOR SELECT TO anon, authenticated USING (true);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='team_trajectory_summaries'
      AND policyname='service_role_all_team_trajectory_summaries'
  ) THEN
    CREATE POLICY service_role_all_team_trajectory_summaries ON public.team_trajectory_summaries
      FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_team_trajectory_summaries_agency
  ON public.team_trajectory_summaries(agency_id);

COMMENT ON TABLE public.team_trajectory_summaries IS
  'LLM-summarized recent behavioral trajectory per active team member. Written by team-trajectory-summarize edge fn. Displayed in Team/Members expanded row.';
