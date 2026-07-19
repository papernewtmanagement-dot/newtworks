-- Multi-PDF payroll emails (one msg carries multiple pay-period PDFs) collide on
-- the old idx_payroll_runs_gmail_msg unique index. Relax to compound
-- (gmail_message_id, pay_period_end) so dedup still holds within a pay period
-- but one message can service multiple periods.
DROP INDEX IF EXISTS public.idx_payroll_runs_gmail_msg;

CREATE UNIQUE INDEX IF NOT EXISTS idx_payroll_runs_gmail_msg
  ON public.payroll_runs (gmail_message_id, pay_period_end)
  WHERE gmail_message_id IS NOT NULL;
