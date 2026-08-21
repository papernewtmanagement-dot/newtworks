-- Daily hours + location (Mon-Fri)
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS mon_hours numeric(4,2),
  ADD COLUMN IF NOT EXISTS mon_location text,
  ADD COLUMN IF NOT EXISTS tue_hours numeric(4,2),
  ADD COLUMN IF NOT EXISTS tue_location text,
  ADD COLUMN IF NOT EXISTS wed_hours numeric(4,2),
  ADD COLUMN IF NOT EXISTS wed_location text,
  ADD COLUMN IF NOT EXISTS thu_hours numeric(4,2),
  ADD COLUMN IF NOT EXISTS thu_location text,
  ADD COLUMN IF NOT EXISTS fri_hours numeric(4,2),
  ADD COLUMN IF NOT EXISTS fri_location text;

-- Location CHECK constraints — guard against accidental free-text values.
-- Aligned with time_clock_entries.work_location vocabulary.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'weekly_cpr_team_detail_mon_location_check') THEN
    ALTER TABLE public.weekly_cpr_team_detail ADD CONSTRAINT weekly_cpr_team_detail_mon_location_check
      CHECK (mon_location IS NULL OR mon_location IN ('in_office','remote'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'weekly_cpr_team_detail_tue_location_check') THEN
    ALTER TABLE public.weekly_cpr_team_detail ADD CONSTRAINT weekly_cpr_team_detail_tue_location_check
      CHECK (tue_location IS NULL OR tue_location IN ('in_office','remote'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'weekly_cpr_team_detail_wed_location_check') THEN
    ALTER TABLE public.weekly_cpr_team_detail ADD CONSTRAINT weekly_cpr_team_detail_wed_location_check
      CHECK (wed_location IS NULL OR wed_location IN ('in_office','remote'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'weekly_cpr_team_detail_thu_location_check') THEN
    ALTER TABLE public.weekly_cpr_team_detail ADD CONSTRAINT weekly_cpr_team_detail_thu_location_check
      CHECK (thu_location IS NULL OR thu_location IN ('in_office','remote'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'weekly_cpr_team_detail_fri_location_check') THEN
    ALTER TABLE public.weekly_cpr_team_detail ADD CONSTRAINT weekly_cpr_team_detail_fri_location_check
      CHECK (fri_location IS NULL OR fri_location IN ('in_office','remote'));
  END IF;
END $$;

-- Activity columns
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS quotes_discussed integer,
  ADD COLUMN IF NOT EXISTS quotes_net integer,
  ADD COLUMN IF NOT EXISTS sales_points numeric(8,2);

-- Pay breakdown columns
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS weekly_pay numeric(10,2),
  ADD COLUMN IF NOT EXISTS base_advance numeric(10,2),
  ADD COLUMN IF NOT EXISTS health_bonus numeric(10,2),
  ADD COLUMN IF NOT EXISTS service_surge_share numeric(10,2),
  ADD COLUMN IF NOT EXISTS true_pay_bonus numeric(10,2),
  ADD COLUMN IF NOT EXISTS manager_bonus numeric(10,2),
  ADD COLUMN IF NOT EXISTS agency_profit_share numeric(10,2);
