-- ============================================================
-- TEAM TELEGRAM CHECKIN INFRASTRUCTURE
-- 3 tables to support the weekday 8:25 / 12:00 / 17:00 checkin loop:
--   team_telegram_map     -> identity mapping (telegram_user_id -> team member)
--   team_checkins         -> individual responses (one row per person per checkin)
--   team_checkin_runs     -> per-cycle state (reminder sent, missing tagged, results compiled)
-- ============================================================

-- 1. Identity mapping: telegram_user_id -> team member
CREATE TABLE IF NOT EXISTS public.team_telegram_map (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  team_id uuid REFERENCES public.team(id),
  telegram_user_id bigint NOT NULL,
  telegram_username text,
  telegram_first_name text,
  telegram_last_name text,
  is_excluded boolean NOT NULL DEFAULT false,
  excluded_reason text,
  mapping_method text CHECK (mapping_method IN ('auto_first_name', 'manual', 'discovered_unmapped')),
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS team_telegram_map_user_unique
  ON public.team_telegram_map (agency_id, telegram_user_id);

CREATE INDEX IF NOT EXISTS team_telegram_map_team_id_idx
  ON public.team_telegram_map (team_id) WHERE team_id IS NOT NULL;

COMMENT ON TABLE public.team_telegram_map IS
  'Maps Telegram user_id to team_id. Auto-populated by inbound message handler. Marie Story and other non-team Telegram users get is_excluded=true so checkin logic skips them.';

-- 2. Individual checkin responses (one row per team member per checkin)
CREATE TABLE IF NOT EXISTS public.team_checkins (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  checkin_date date NOT NULL,
  checkin_type text NOT NULL CHECK (checkin_type IN ('morning', 'midday', 'eod')),
  team_id uuid REFERENCES public.team(id),
  telegram_user_id bigint,
  telegram_first_name text,
  raw_message text,
  quotes_week numeric,
  sales_points_quarter numeric,
  parse_status text CHECK (parse_status IN ('parsed', 'unparseable', 'partial')),
  received_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS team_checkins_unique_response
  ON public.team_checkins (agency_id, checkin_date, checkin_type, team_id)
  WHERE team_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS team_checkins_lookup_idx
  ON public.team_checkins (agency_id, checkin_date, checkin_type);

COMMENT ON TABLE public.team_checkins IS
  'One row per team member per checkin. quotes_week = total quotes discussed this week. sales_points_quarter = total sales points this quarter. Parsed from "N/M" format in group messages.';

-- 3. Per-cycle state: tracks each reminder run from send through compile
CREATE TABLE IF NOT EXISTS public.team_checkin_runs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  checkin_date date NOT NULL,
  checkin_type text NOT NULL CHECK (checkin_type IN ('morning', 'midday', 'eod')),
  reminder_sent_at timestamptz,
  reminder_message_id bigint,
  reminder_text text,
  tag_missing_at timestamptz,
  tag_missing_message_id bigint,
  tag_missing_team_ids uuid[],
  compile_results_at timestamptz,
  compile_results_message_id bigint,
  total_quotes_week numeric,
  total_sales_points_quarter numeric,
  responders_count int,
  expected_count int,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS team_checkin_runs_unique
  ON public.team_checkin_runs (agency_id, checkin_date, checkin_type);

COMMENT ON TABLE public.team_checkin_runs IS
  'State tracker for each checkin cycle: T+0 reminder, T+5 tag-missing, T+15 compile-results. One row per (date, type). Used by morning reminder to fetch prior EOD totals.';

-- 4. RLS policies (mirror existing pattern from team table)
ALTER TABLE public.team_telegram_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_checkins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_checkin_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_telegram_map_agency_isolation ON public.team_telegram_map;
CREATE POLICY team_telegram_map_agency_isolation ON public.team_telegram_map
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS team_checkins_agency_isolation ON public.team_checkins;
CREATE POLICY team_checkins_agency_isolation ON public.team_checkins
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS team_checkin_runs_agency_isolation ON public.team_checkin_runs;
CREATE POLICY team_checkin_runs_agency_isolation ON public.team_checkin_runs
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- 5. Pre-populate Marie's exclusion record so she's never tagged as missing.
--    (telegram_user_id 7791389800, captured from getUpdates earlier)
INSERT INTO public.team_telegram_map
  (agency_id, telegram_user_id, telegram_first_name, telegram_last_name, is_excluded, excluded_reason, mapping_method)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 7791389800, 'Marie', 'Story', true,
   'Not on active team roster — family/admin member of PJS Agency Telegram group. Excluded from checkin tracking.',
   'manual')
ON CONFLICT (agency_id, telegram_user_id) DO NOTHING;
