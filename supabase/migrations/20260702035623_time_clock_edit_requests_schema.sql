
-- Audit columns on time_clock_entries to preserve pre-edit values
ALTER TABLE public.time_clock_entries
  ADD COLUMN IF NOT EXISTS original_clock_in_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS original_clock_out_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS edit_request_id UUID;

-- Edit request table
CREATE TABLE IF NOT EXISTS public.time_clock_edit_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid REFERENCES public.agency(id),
  team_member_id UUID NOT NULL REFERENCES public.team(id),
  punch_date DATE NOT NULL,
  edit_type TEXT NOT NULL CHECK (edit_type IN ('missed_clock_in','missed_clock_out','wrong_time','missed_shift')),
  target_entry_id UUID REFERENCES public.time_clock_entries(id),
  requested_clock_in_at TIMESTAMPTZ,
  requested_clock_out_at TIMESTAMPTZ,
  reason TEXT NOT NULL CHECK (length(trim(reason)) >= 3),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','denied','cancelled')),
  submitted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  reviewed_at TIMESTAMPTZ,
  reviewed_by_user_id UUID REFERENCES public.users(id),
  review_note TEXT,
  telegram_notified_at TIMESTAMPTZ,
  requester_notified_at TIMESTAMPTZ,
  resulting_entry_id UUID REFERENCES public.time_clock_entries(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- FK from entries back to originating edit request (circular, added after table exists)
ALTER TABLE public.time_clock_entries
  DROP CONSTRAINT IF EXISTS time_clock_entries_edit_request_id_fkey;
ALTER TABLE public.time_clock_entries
  ADD CONSTRAINT time_clock_entries_edit_request_id_fkey
    FOREIGN KEY (edit_request_id) REFERENCES public.time_clock_edit_requests(id);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_tcer_pending ON public.time_clock_edit_requests(status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_tcer_team_date ON public.time_clock_edit_requests(team_member_id, punch_date DESC);
CREATE INDEX IF NOT EXISTS idx_tcer_agency_status ON public.time_clock_edit_requests(agency_id, status);

-- RLS mirrors time_clock_entries permissive pattern (internal app)
ALTER TABLE public.time_clock_edit_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS time_clock_edit_requests_anon_read ON public.time_clock_edit_requests;
DROP POLICY IF EXISTS time_clock_edit_requests_authenticated_read ON public.time_clock_edit_requests;
DROP POLICY IF EXISTS time_clock_edit_requests_authenticated_write ON public.time_clock_edit_requests;

CREATE POLICY time_clock_edit_requests_anon_read ON public.time_clock_edit_requests FOR SELECT TO anon USING (true);
CREATE POLICY time_clock_edit_requests_authenticated_read ON public.time_clock_edit_requests FOR SELECT TO authenticated USING (true);
CREATE POLICY time_clock_edit_requests_authenticated_write ON public.time_clock_edit_requests FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.tcer_touch_updated_at() RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_tcer_updated_at ON public.time_clock_edit_requests;
CREATE TRIGGER trg_tcer_updated_at
  BEFORE UPDATE ON public.time_clock_edit_requests
  FOR EACH ROW EXECUTE FUNCTION public.tcer_touch_updated_at();

-- Current-week validation trigger (Sunday–Saturday agency week)
-- Only enforced on INSERT for pending requests; approvals can process regardless
CREATE OR REPLACE FUNCTION public.tcer_enforce_current_week() RETURNS TRIGGER AS $$
DECLARE
  week_start DATE;
  week_end DATE;
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status = 'pending' THEN
    week_start := CURRENT_DATE - EXTRACT(DOW FROM CURRENT_DATE)::INT;
    week_end := week_start + 6;
    IF NEW.punch_date < week_start OR NEW.punch_date > week_end THEN
      RAISE EXCEPTION 'Edit requests must be for the current agency week (% through %). Requested date: %', week_start, week_end, NEW.punch_date;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_tcer_current_week ON public.time_clock_edit_requests;
CREATE TRIGGER trg_tcer_current_week
  BEFORE INSERT ON public.time_clock_edit_requests
  FOR EACH ROW EXECUTE FUNCTION public.tcer_enforce_current_week();
