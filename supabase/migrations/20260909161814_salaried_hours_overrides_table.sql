-- Per-day worked-hours override for SALARIED teammates on the CPR Hours section.
-- Salaried hours are an assumption (8 minus approved time off). There was no way to
-- state a real partial day: a half-day time-off request only produces 4, and an hourly
-- time clock entry is not read for a salaried person. This table is that statement.
-- Hourly teammates are deliberately out of scope: they already have time_clock_entries
-- plus time_clock_edit_requests as the sanctioned correction path, and their hours drive
-- Retention Points pay. A second source for hourly would compete with the time clock.
CREATE TABLE IF NOT EXISTS public.salaried_hours_overrides (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       uuid NOT NULL,
  team_member_id  uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  work_date       date NOT NULL,
  hours           numeric NOT NULL CHECK (hours >= 0 AND hours <= 24),
  note            text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS salaried_hours_overrides_one_per_day
  ON public.salaried_hours_overrides (agency_id, team_member_id, work_date);

ALTER TABLE public.salaried_hours_overrides ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                 AND tablename='salaried_hours_overrides' AND policyname='salaried_hours_overrides_admin_read') THEN
    CREATE POLICY salaried_hours_overrides_admin_read ON public.salaried_hours_overrides
      FOR SELECT USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                 AND tablename='salaried_hours_overrides' AND policyname='salaried_hours_overrides_admin_insert') THEN
    CREATE POLICY salaried_hours_overrides_admin_insert ON public.salaried_hours_overrides
      FOR INSERT WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                 AND tablename='salaried_hours_overrides' AND policyname='salaried_hours_overrides_admin_update') THEN
    CREATE POLICY salaried_hours_overrides_admin_update ON public.salaried_hours_overrides
      FOR UPDATE USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
      WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                 AND tablename='salaried_hours_overrides' AND policyname='salaried_hours_overrides_admin_delete') THEN
    CREATE POLICY salaried_hours_overrides_admin_delete ON public.salaried_hours_overrides
      FOR DELETE USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
  END IF;
END $$;

DROP TRIGGER IF EXISTS trg_salaried_hours_overrides_updated_at ON public.salaried_hours_overrides;
CREATE TRIGGER trg_salaried_hours_overrides_updated_at
  BEFORE UPDATE ON public.salaried_hours_overrides
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.salaried_hours_overrides IS
  'Explicit per-day worked hours for a SALARIED teammate, read by get_weekly_cpr_hours in place of the assumed 8-hour day. Does not change pay: salaried base is prorated by workdays employed, not by hours. Hourly teammates use time_clock_entries instead.';
