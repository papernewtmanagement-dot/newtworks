-- Peter directive 2026-08-06: financials screens only viewable by admin/owner
-- (is_agency_admin() = owner + manager roles). Re-scopes SELECT policies on the
-- 9 raw financial tables to admin-only, ANDing onto existing expressions.
-- statement_balances excluded: its policy is ALL-command, deferred for a
-- separate read/write split (see report). bank_transactions' service_role
-- ALL policy is untouched — service role bypasses RLS regardless.
ALTER POLICY anon_read_account_starting_balances ON public.account_starting_balances
  TO authenticated USING ( (true) AND public.is_agency_admin() );
ALTER POLICY anon_read_bank_accounts ON public.bank_accounts
  TO authenticated USING ( (true) AND public.is_agency_admin() );
ALTER POLICY authenticated_select_bank_register_preliminary ON public.bank_register_preliminary
  TO authenticated USING ( (true) AND public.is_agency_admin() );
ALTER POLICY anon_read_bank_transactions ON public.bank_transactions
  TO authenticated USING ( (true) AND public.is_agency_admin() );
ALTER POLICY anon_read_business_entities ON public.business_entities
  TO authenticated USING ( (true) AND public.is_agency_admin() );
ALTER POLICY anon_read_credit_accounts ON public.credit_accounts
  TO authenticated USING ( (true) AND public.is_agency_admin() );
ALTER POLICY anon_read_credit_transactions ON public.credit_transactions
  TO authenticated USING ( (true) AND public.is_agency_admin() );
ALTER POLICY anon_read_opening_balances ON public.opening_balances
  TO authenticated USING ( (true) AND public.is_agency_admin() );
