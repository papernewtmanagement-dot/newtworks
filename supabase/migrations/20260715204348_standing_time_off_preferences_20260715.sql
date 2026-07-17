-- =====================================================================
-- Standing Time Off Preferences — canonical home for recurring patterns
-- Replaces the ad-hoc team.four_day_off_day text field.
-- Approval flow: submit as time_off_requests row with request_type=
-- 'standing_time_off_preference' + standing_pref_days payload; on
-- approval a trigger inserts one row per day into this table.
-- Materialization: materialize_standing_time_off(week_start) writes
-- concrete time_off_requests rows for a target week, gated by trigger.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.standing_time_off_preferences (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             UUID NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  team_member_id        UUID NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,

  -- Pattern: which weekday, which part, what kind
  day_of_week           TEXT NOT NULL,
  day_part              TEXT NOT NULL,
  pattern               TEXT NOT NULL,
  is_paid               BOOLEAN NOT NULL DEFAULT true,

  -- Trigger: when does this pattern apply?
  trigger_type          TEXT NOT NULL DEFAULT 'always',

  -- Bookkeeping
  effective_from        DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_until       DATE,
  approved_by_team_id   UUID REFERENCES public.team(id),
  approved_at           TIMESTAMPTZ,
  source_request_id     UUID REFERENCES public.time_off_requests(id) ON DELETE SET NULL,
  notes                 TEXT,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  archived_at           TIMESTAMPTZ,

  CONSTRAINT stop_day_of_week_check
    CHECK (day_of_week = ANY (ARRAY['monday','tuesday','wednesday','thursday','friday'])),
  CONSTRAINT stop_day_part_check
    CHECK (day_part = ANY (ARRAY['morning','afternoon','full'])),
  CONSTRAINT stop_pattern_check
    CHECK (pattern = ANY (ARRAY['off','remote'])),
  CONSTRAINT stop_trigger_type_check
    CHECK (trigger_type = ANY (ARRAY['always','wtw_won_prior_week']))
);

CREATE INDEX IF NOT EXISTS idx_stop_active
  ON public.standing_time_off_preferences (agency_id, team_member_id, day_of_week)
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_stop_agency
  ON public.standing_time_off_preferences (agency_id)
  WHERE archived_at IS NULL;

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.tg_stop_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS stop_touch_updated_at ON public.standing_time_off_preferences;
CREATE TRIGGER stop_touch_updated_at
  BEFORE UPDATE ON public.standing_time_off_preferences
  FOR EACH ROW EXECUTE FUNCTION public.tg_stop_touch_updated_at();

-- RLS: agency-scoped read for authenticated; writes via SECURITY DEFINER RPCs / trigger only
ALTER TABLE public.standing_time_off_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stop_read ON public.standing_time_off_preferences;
CREATE POLICY stop_read ON public.standing_time_off_preferences
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS stop_write_admin ON public.standing_time_off_preferences;
CREATE POLICY stop_write_admin ON public.standing_time_off_preferences
  FOR ALL TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role IN ('owner','manager')
    )
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.role IN ('owner','manager')
    )
  );

COMMENT ON TABLE  public.standing_time_off_preferences IS
  'Canonical home for recurring/standing time-off + remote patterns per teammate. Replaces the deprecated team.four_day_off_day text field. Auto-materialized into time_off_requests weekly by materialize_standing_time_off().';
COMMENT ON COLUMN public.standing_time_off_preferences.trigger_type IS
  '"always" = every week; "wtw_won_prior_week" = only weeks after we won Win the Week the prior week.';
COMMENT ON COLUMN public.standing_time_off_preferences.pattern IS
  '"off" = time off (paid or unpaid per is_paid); "remote" = still working, remotely, still paid.';
COMMENT ON COLUMN public.standing_time_off_preferences.day_part IS
  '"morning" = 8:30 AM - 1 PM CT; "afternoon" = 1 PM - 5:30 PM CT; "full" = full workday.';;