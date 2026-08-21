-- Phase 3: SELECT policies for two tables that the frontend reads but were
-- RLS-blocked at SELECT, returning silent empty arrays in CashRegister.

CREATE POLICY "anon_read_account_starting_balances" ON public.account_starting_balances
  FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "anon_read_bank_register_weekly_snapshot" ON public.bank_register_weekly_snapshot
  FOR SELECT TO anon, authenticated
  USING (true);
