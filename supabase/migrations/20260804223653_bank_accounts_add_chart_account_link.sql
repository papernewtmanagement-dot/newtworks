-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-04 22:36:53 UTC (ledger name: bank_accounts_add_chart_account_link) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260804223653.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Give bank_accounts the same chart link credit_accounts already has, so
-- statement routing can be resolved from data instead of a hardcoded list.
ALTER TABLE public.bank_accounts
  ADD COLUMN IF NOT EXISTS chart_account_id uuid REFERENCES public.chart_of_accounts(id);

-- Populate from filed-statement evidence. Each pairing below is the account_code
-- that statement_balances has historically recorded against that last4 (5-8
-- statements each), except 6608 which has no filed statement yet and resolves to
-- the single chart row carrying 6608 in its name.
--   0353->1070  2545->1071  3977->1012  4335->1011
--   6730->1072  6755->1073  6596->1076  6608->1075
-- 3977 deliberately maps to 1012 and NOT 1050: 1050's name also carries 3977 but
-- every 3977 statement files to 1012. Resolving via this column avoids that trap.
WITH pairs(last4, code) AS (VALUES
  ('0353','1070'), ('2545','1071'), ('3977','1012'), ('4335','1011'),
  ('6730','1072'), ('6755','1073'), ('6596','1076'), ('6608','1075')
)
UPDATE public.bank_accounts ba
SET chart_account_id = coa.id, updated_at = now()
FROM pairs p
JOIN public.chart_of_accounts coa
  ON coa.account_code = p.code
 AND coa.agency_id = '126794dd-25ff-47d2-a436-724499733365'
WHERE ba.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND ba.account_number_last4 = p.last4
  AND ba.chart_account_id IS NULL;
