-- One row per person per week (Sun-anchored). New messages append into raw_responses.
CREATE TABLE IF NOT EXISTS public.team_weekly_wrapups (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  team_id uuid NOT NULL REFERENCES public.team(id),
  week_start_date date NOT NULL,                     -- Sunday of the closing week
  week_ending_date date NOT NULL,                    -- Saturday of the closing week (denormalized for ease of read)
  raw_responses text NOT NULL DEFAULT '',
  message_count int NOT NULL DEFAULT 0,
  first_received_at timestamptz,
  last_received_at timestamptz,
  -- Future structured fields (LLM-parsed in a later session)
  greatest_obstacle text,
  next_week_goal text,
  office_efficiency_idea text,
  team_brags text,
  parse_status text NOT NULL DEFAULT 'unparsed' CHECK (parse_status IN ('unparsed','parsed','parse_failed')),
  parsed_at timestamptz,
  -- Audit
  source text NOT NULL DEFAULT 'telegram_group',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS team_weekly_wrapups_team_week_unique
  ON public.team_weekly_wrapups (team_id, week_start_date);

CREATE INDEX IF NOT EXISTS team_weekly_wrapups_agency_week_idx
  ON public.team_weekly_wrapups (agency_id, week_start_date DESC);

ALTER TABLE public.team_weekly_wrapups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_weekly_wrapups_agency_isolation ON public.team_weekly_wrapups;
CREATE POLICY team_weekly_wrapups_agency_isolation ON public.team_weekly_wrapups
  FOR ALL USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.set_team_weekly_wrapups_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS team_weekly_wrapups_updated_at_trg ON public.team_weekly_wrapups;
CREATE TRIGGER team_weekly_wrapups_updated_at_trg
  BEFORE UPDATE ON public.team_weekly_wrapups
  FOR EACH ROW EXECUTE FUNCTION public.set_team_weekly_wrapups_updated_at();
