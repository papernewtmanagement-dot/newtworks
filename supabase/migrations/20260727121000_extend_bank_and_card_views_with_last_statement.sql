-- STEP 3: extend v_bank_balances + v_card_balances to expose last-statement data.
-- Additive: new columns appended, existing columns unchanged.

CREATE OR REPLACE VIEW public.v_bank_balances AS
WITH cfg AS (
  SELECT settings.setting_value::date AS anchor_date
  FROM settings
  WHERE settings.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND settings.setting_key = 'gl_anchor_date'::text
),
active_accts AS (
  SELECT ba.id AS bank_account_id, ba.agency_id, ba.business_entity_id,
         ba.account_name, ba.institution, ba.account_type, ba.account_number_last4,
         coa.id AS chart_account_id, coa.account_code
  FROM bank_accounts ba
  LEFT JOIN chart_of_accounts coa
    ON coa.account_name = ba.account_name AND coa.account_type = 'asset'::text
  WHERE ba.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ba.is_active = true
),
anchor AS (
  SELECT ob.account_code, ob.opening_balance
  FROM opening_balances ob CROSS JOIN cfg
  WHERE ob.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ob.as_of_date = cfg.anchor_date
),
ledger AS (
  SELECT coa.account_code,
         round(sum(jl.debit) - sum(jl.credit), 2) AS activity_since_anchor,
         max(je.entry_date) AS last_entry_date,
         count(DISTINCT je.id) AS entry_count
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  CROSS JOIN cfg
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND je.entry_date > cfg.anchor_date
    AND coa.account_type = 'asset'::text
  GROUP BY coa.account_code
),
last_stmt AS (
  SELECT DISTINCT ON (account_code)
    account_code,
    statement_period_end AS last_statement_close_date,
    closing_balance AS last_statement_balance,
    source AS last_statement_source,
    notes AS last_statement_notes
  FROM statement_balances
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND account_kind = 'bank'
  ORDER BY account_code, statement_period_end DESC
)
SELECT
  a.agency_id, a.bank_account_id, a.chart_account_id, a.account_code, a.account_name,
  a.institution, a.account_type, a.account_number_last4,
  COALESCE(an.opening_balance, 0::numeric) AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0::numeric) AS activity_since_anchor,
  round(COALESCE(an.opening_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric), 2) AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0::bigint) AS entry_count,
  an.opening_balance IS NULL AND l.activity_since_anchor IS NULL AS needs_statement,
  (COALESCE(an.opening_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric)) < 0::numeric AS needs_review,
  a.business_entity_id,
  ls.last_statement_close_date,
  ls.last_statement_balance,
  ls.last_statement_source,
  ls.last_statement_notes
FROM active_accts a
LEFT JOIN anchor an ON an.account_code = a.account_code
LEFT JOIN ledger l ON l.account_code = a.account_code
LEFT JOIN last_stmt ls ON ls.account_code = a.account_code
ORDER BY a.account_name;


CREATE OR REPLACE VIEW public.v_card_balances AS
WITH cfg AS (
  SELECT settings.setting_value::date AS anchor_date
  FROM settings
  WHERE settings.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND settings.setting_key = 'gl_anchor_date'::text
),
anchor AS (
  SELECT ob.account_code, ob.opening_balance
  FROM opening_balances ob CROSS JOIN cfg
  WHERE ob.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ob.as_of_date = cfg.anchor_date
),
ledger AS (
  SELECT coa_1.id AS chart_account_id,
         coa_1.account_code,
         round(sum(jl.credit) - sum(jl.debit), 2) AS activity_since_anchor,
         max(je.entry_date) AS last_entry_date,
         count(DISTINCT je.id) AS entry_count
  FROM journal_entries je
  JOIN journal_lines jl ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa_1 ON coa_1.id = jl.account_id
  CROSS JOIN cfg
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND je.entry_date > cfg.anchor_date
    AND coa_1.account_type = 'liability'::text
  GROUP BY coa_1.id, coa_1.account_code
),
last_stmt AS (
  SELECT DISTINCT ON (account_code)
    account_code,
    statement_period_end AS last_statement_close_date,
    closing_balance AS last_statement_balance,
    source AS last_statement_source,
    notes AS last_statement_notes
  FROM statement_balances
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND account_kind = 'credit'
  ORDER BY account_code, statement_period_end DESC
)
SELECT
  ca.agency_id, ca.id AS credit_account_id, ca.account_name, ca.institution,
  ca.account_type, ca.account_number_last4, ca.credit_limit, ca.interest_rate,
  ca.minimum_payment, ca.payment_due_day, ca.chart_account_id,
  COALESCE(an.opening_balance, 0::numeric) AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0::numeric) AS activity_since_anchor,
  round(COALESCE(an.opening_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric), 2) AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0::bigint) AS entry_count,
  ca.account_number_last4 IS NULL AS needs_last4,
  (COALESCE(an.opening_balance, 0::numeric) + COALESCE(l.activity_since_anchor, 0::numeric)) < 0::numeric AS needs_review,
  ca.business_entity_id,
  ls.last_statement_close_date,
  ls.last_statement_balance,
  ls.last_statement_source,
  ls.last_statement_notes
FROM credit_accounts ca
LEFT JOIN chart_of_accounts coa ON coa.id = ca.chart_account_id
LEFT JOIN anchor an ON an.account_code = coa.account_code
LEFT JOIN ledger l ON l.chart_account_id = ca.chart_account_id
LEFT JOIN last_stmt ls ON ls.account_code = coa.account_code
WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND ca.is_active = true
ORDER BY ca.account_name;
