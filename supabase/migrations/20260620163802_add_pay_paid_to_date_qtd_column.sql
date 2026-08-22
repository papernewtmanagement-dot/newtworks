-- New column for the manually-entered QTD paid-to-date amount used by True Pay Bonus.
-- NULL means "not yet entered for this team member this week."
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS pay_paid_to_date_qtd numeric;

COMMENT ON COLUMN public.weekly_cpr_team_detail.pay_paid_to_date_qtd IS
  'Total $ paid to this team member this quarter through end of last pay period (manual entry, source = SurePayroll). Used as the lower bound for True Pay Bonus computation. NULL = not yet entered for this week.';
