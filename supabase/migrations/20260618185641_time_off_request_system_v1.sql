-- Phase 1 foundation: time off / remote / 4-day request system
-- Spec source: persistent_memory row id fcaa841a-68f0-481c-a348-9d07f1699a85

-- 1. Coverage rules (referenced by request flow)
CREATE TABLE IF NOT EXISTS public.time_off_coverage_rules (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  rule_name text NOT NULL,
  rule_description text,
  rule_logic jsonb NOT NULL,
  severity text NOT NULL CHECK (severity IN ('red', 'yellow')),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_time_off_coverage_rules_agency_active
  ON public.time_off_coverage_rules (agency_id, is_active);

-- 2. Time off requests
CREATE TABLE IF NOT EXISTS public.time_off_requests (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id uuid NOT NULL,
  requester_team_id uuid NOT NULL REFERENCES public.team(id),
  request_type text NOT NULL CHECK (request_type IN (
    'pto_full_day',
    'pto_half_day',
    'sick',
    'remote_day',
    'remote_half_day',
    'four_day_off_change'
  )),
  start_date date NOT NULL,
  end_date date NOT NULL,
  partial_day text CHECK (partial_day IN ('morning', 'afternoon', 'none')) DEFAULT 'none',
  notes text,
  -- proposed new value only used when request_type = 'four_day_off_change'
  proposed_four_day_off_day text CHECK (proposed_four_day_off_day IN (
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'
  )),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending',
    'voting',
    'awaiting_decision',
    'approved',
    'denied',
    'expired',
    'cancelled',
    'flagged_case_by_case'
  )),
  -- pre-vote gates (results stored for audit)
  notice_check_result jsonb,
  eligibility_check_result jsonb,
  coverage_check_result jsonb,
  -- vote window
  vote_opened_at timestamptz,
  vote_closes_at timestamptz,
  -- decision
  decided_by_team_id uuid REFERENCES public.team(id),
  decided_at timestamptz,
  decision_note text,
  emergency_override boolean NOT NULL DEFAULT false,
  -- calendar
  calendar_event_id text,
  calendar_name text,
  -- audit
  submitted_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT time_off_requests_date_order CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS idx_time_off_requests_agency_status
  ON public.time_off_requests (agency_id, status);
CREATE INDEX IF NOT EXISTS idx_time_off_requests_requester
  ON public.time_off_requests (requester_team_id, submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_time_off_requests_dates
  ON public.time_off_requests (agency_id, start_date, end_date)
  WHERE status IN ('approved', 'voting', 'awaiting_decision');

-- 3. Votes
CREATE TABLE IF NOT EXISTS public.time_off_votes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  request_id uuid NOT NULL REFERENCES public.time_off_requests(id) ON DELETE CASCADE,
  voter_team_id uuid NOT NULL REFERENCES public.team(id),
  vote text NOT NULL CHECK (vote IN ('yes', 'no', 'abstain')),
  reason text,
  voted_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (request_id, voter_team_id)
);

CREATE INDEX IF NOT EXISTS idx_time_off_votes_request
  ON public.time_off_votes (request_id);

-- 4. team.four_day_off_day (preset per-AM off day when team wins the week)
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS four_day_off_day text;

-- Add the CHECK constraint separately so it's idempotent
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'team_four_day_off_day_check'
      AND table_name = 'team'
  ) THEN
    ALTER TABLE public.team
      ADD CONSTRAINT team_four_day_off_day_check
      CHECK (four_day_off_day IS NULL OR four_day_off_day IN (
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'
      ));
  END IF;
END $$;

-- 5. updated_at triggers (use existing or create simple ones)
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger AS $func$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$func$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_time_off_requests_updated_at ON public.time_off_requests;
CREATE TRIGGER trg_time_off_requests_updated_at
  BEFORE UPDATE ON public.time_off_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_time_off_coverage_rules_updated_at ON public.time_off_coverage_rules;
CREATE TRIGGER trg_time_off_coverage_rules_updated_at
  BEFORE UPDATE ON public.time_off_coverage_rules
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
