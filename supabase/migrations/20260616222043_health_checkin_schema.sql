-- 1. Loosen the checkin_type constraints to allow 'health_eve'
ALTER TABLE public.team_checkin_runs DROP CONSTRAINT IF EXISTS team_checkin_runs_checkin_type_check;
ALTER TABLE public.team_checkin_runs ADD CONSTRAINT team_checkin_runs_checkin_type_check
  CHECK (checkin_type = ANY (ARRAY['morning'::text, 'midday'::text, 'eod'::text, 'health_eve'::text]));

ALTER TABLE public.team_checkins DROP CONSTRAINT IF EXISTS team_checkins_checkin_type_check;
ALTER TABLE public.team_checkins ADD CONSTRAINT team_checkins_checkin_type_check
  CHECK (checkin_type = ANY (ARRAY['morning'::text, 'midday'::text, 'eod'::text, 'health_eve'::text]));

-- 2. team_health_checkins: one logical entry per (team_id, log_date)
CREATE TABLE IF NOT EXISTS public.team_health_checkins (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  team_id uuid NOT NULL REFERENCES public.team(id),
  log_date date NOT NULL,
  week_start_date date NOT NULL,
  hit_today boolean,
  week_total_override int,
  raw_response text,
  parse_status text DEFAULT 'parsed' CHECK (parse_status IN ('parsed','unparseable','partial')),
  telegram_user_id bigint,
  telegram_first_name text,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  submitted_by_team_id uuid,
  submitted_by_telegram_user_id bigint,
  is_proxy_submission boolean GENERATED ALWAYS AS (
    team_id IS DISTINCT FROM submitted_by_team_id
  ) STORED,
  source_message_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT team_health_checkins_value_sanity CHECK (
    hit_today IS NOT NULL OR week_total_override IS NOT NULL
  ),
  CONSTRAINT team_health_checkins_override_range CHECK (
    week_total_override IS NULL OR (week_total_override >= 0 AND week_total_override <= 14)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS team_health_checkins_team_date_unique
  ON public.team_health_checkins (team_id, log_date);

CREATE INDEX IF NOT EXISTS team_health_checkins_agency_week_idx
  ON public.team_health_checkins (agency_id, week_start_date);

ALTER TABLE public.team_health_checkins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_health_checkins_agency_isolation ON public.team_health_checkins;
CREATE POLICY team_health_checkins_agency_isolation ON public.team_health_checkins
  FOR ALL USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- 3. health_quotes: rotating pool for the 7 PM prompt
CREATE TABLE IF NOT EXISTS public.health_quotes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  quote_text text NOT NULL,
  attribution text,
  flavor text NOT NULL DEFAULT 'inspiring' CHECK (flavor IN ('inspiring','funny','both')),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.health_quotes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS health_quotes_agency_isolation ON public.health_quotes;
CREATE POLICY health_quotes_agency_isolation ON public.health_quotes
  FOR ALL USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
