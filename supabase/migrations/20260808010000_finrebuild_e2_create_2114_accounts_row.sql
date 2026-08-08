-- finrebuild_e2_create_2114_accounts_row
-- D18: chart code 2114 ("PSS — CITI Personal Card (agency use)", Peter Story
-- State Farm entity) has a statement on file (document a10405e0, "Citi
-- PaperNewt 26-07.pdf", source_account_code=2114) but no accounts row.
-- Shares last4 1247 with chart code 2140's Citi card (PaperNewt entity) —
-- same physical card number, two entity-scoped chart accounts, matching
-- the documented shared-last4 pattern in document-processor's account
-- resolution comments.
INSERT INTO public.accounts (
  id, agency_id, business_entity_id, account_kind, account_name,
  institution, account_number_last4, chart_account_id, is_active
) VALUES (
  gen_random_uuid(),
  '126794dd-25ff-47d2-a436-724499733365',
  'b2222222-2222-2222-2222-222222222222',
  'credit',
  'PSS — CITI Personal Card (agency use)',
  'Citi',
  '1247',
  'fb91dbc6-6558-4f20-be06-950285afe3b3',
  true
);
