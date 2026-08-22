ALTER TABLE public.weekly_cpr_team_detail
  DROP COLUMN IF EXISTS mon_hours,
  DROP COLUMN IF EXISTS mon_location,
  DROP COLUMN IF EXISTS tue_hours,
  DROP COLUMN IF EXISTS tue_location,
  DROP COLUMN IF EXISTS wed_hours,
  DROP COLUMN IF EXISTS wed_location,
  DROP COLUMN IF EXISTS thu_hours,
  DROP COLUMN IF EXISTS thu_location,
  DROP COLUMN IF EXISTS fri_hours,
  DROP COLUMN IF EXISTS fri_location,
  DROP COLUMN IF EXISTS quotes_net,
  DROP COLUMN IF EXISTS pay_paid_to_date_qtd;
