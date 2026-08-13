ALTER TABLE public.statement_balances DROP CONSTRAINT statement_balances_account_kind_check;
ALTER TABLE public.statement_balances ADD CONSTRAINT statement_balances_account_kind_check
  CHECK (account_kind = ANY (ARRAY['bank'::text, 'credit'::text, 'investment'::text]));

INSERT INTO public.statement_balances (agency_id, business_entity_id, account_code, account_kind, statement_period_start, statement_period_end, opening_balance, closing_balance, source, notes)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'b2222222-2222-2222-2222-222222222222',
  '1016',
  'investment',
  NULL,
  CURRENT_DATE,
  NULL,
  195000.00,
  'claude_manual_peter_reported_2026_08_13',
  'Peter-reported total principal currently sitting in CDs, 2026-08-13. Ingested bank statements only surfaced $65,000 of CD-purchase transfers (2 withdrawals) plus $25,408.70 of returns - this figure is the true total and takes precedence. Treated as an anchor balance, same pattern as any other statement close; no reconciling entry created for the gap per standing rule against surfacing cutover-style gaps.'
);
