-- ================================================================
-- FINANCIALS MODULE FIXES — 2026-07-16
-- Fixes 3 UI bugs Peter reported after Alvi's document package landed:
--  (1) Prior Years P&L tab hangs on "Loading…" — no RLS SELECT policy
--      on prior_year_pl. Data (~4000 rows, 2019-May 2026) is there;
--      PostgREST returns empty to authenticated client → year list stays
--      empty → year state stays null → loading state never clears.
--  (2) Bank Accounts tab only shows US Bank Income. v_bank_balances
--      was scope-driven off account_codes AND required either an
--      opening_balances anchor OR ledger activity. US Bank Expenses
--      (COA-006) has neither pending June statement, so it's invisible.
--      Refactor to be driven by ACTIVE bank_accounts rows so waiting
--      accounts still appear with a "needs_statement" flag.
--  (3) Credit & Debt has correct balances but Peter can't tell WHICH
--      card is which — no institution, no last-4 shown. v_card_balances
--      already knows institution via the join; add last-4, credit_limit,
--      interest_rate, minimum_payment, payment_due_day, account_type,
--      account_number_last4 so the FE can render "Institution · ••1234".
-- Verified no pg functions reference v_bank_balances or v_card_balances
-- so DROP is safe (FE reads only).
-- ================================================================

-- ─── FIX 1: RLS SELECT on prior_year_pl ────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'prior_year_pl'
      AND policyname = 'prior_year_pl_read_by_agency'
  ) THEN
    CREATE POLICY prior_year_pl_read_by_agency
      ON public.prior_year_pl
      FOR SELECT
      TO authenticated
      USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
  END IF;
END $$;

-- ─── FIX 2: v_bank_balances — driver-set changes from account_codes
--     to ACTIVE bank_accounts rows, adds needs_statement flag ────
DROP VIEW IF EXISTS public.v_bank_balances;

CREATE VIEW public.v_bank_balances AS
WITH cfg AS (
  SELECT setting_value::date AS anchor_date
  FROM settings
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND setting_key = 'gl_anchor_date'
),
active_accts AS (
  SELECT
    ba.id                          AS bank_account_id,
    ba.agency_id,
    ba.account_name,
    ba.institution,
    ba.account_type,
    ba.account_number_last4,
    coa.id                         AS chart_account_id,
    coa.account_code
  FROM bank_accounts ba
  LEFT JOIN chart_of_accounts coa
    ON coa.account_name = ba.account_name
   AND coa.account_type = 'asset'
  WHERE ba.agency_id  = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ba.is_active   = true
),
anchor AS (
  SELECT ob.account_code, ob.opening_balance
  FROM opening_balances ob
  CROSS JOIN cfg
  WHERE ob.agency_id  = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ob.as_of_date = cfg.anchor_date
),
ledger AS (
  SELECT
    coa.account_code,
    ROUND(SUM(jl.debit) - SUM(jl.credit), 2)      AS activity_since_anchor,
    MAX(je.entry_date)                            AS last_entry_date,
    COUNT(DISTINCT je.id)                         AS entry_count
  FROM journal_entries je
  JOIN journal_lines jl        ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa   ON coa.id = jl.account_id
  CROSS JOIN cfg
  WHERE je.agency_id  = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND je.entry_date > cfg.anchor_date
    AND coa.account_type = 'asset'
  GROUP BY coa.account_code
)
SELECT
  a.agency_id,
  a.bank_account_id,
  a.chart_account_id,
  a.account_code,
  a.account_name,
  a.institution,
  a.account_type,
  a.account_number_last4,
  COALESCE(an.opening_balance, 0)::numeric              AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0)::numeric         AS activity_since_anchor,
  ROUND(COALESCE(an.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0), 2)
                                                        AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0)                            AS entry_count,
  (an.opening_balance IS NULL AND l.activity_since_anchor IS NULL)
                                                        AS needs_statement,
  (COALESCE(an.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0)) < 0
                                                        AS needs_review
FROM active_accts a
LEFT JOIN anchor an ON an.account_code = a.account_code
LEFT JOIN ledger l  ON l.account_code = a.account_code
ORDER BY a.account_name;

-- ─── FIX 3: v_card_balances — add missing render fields ──────────
DROP VIEW IF EXISTS public.v_card_balances;

CREATE VIEW public.v_card_balances AS
WITH cfg AS (
  SELECT setting_value::date AS anchor_date
  FROM settings
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND setting_key = 'gl_anchor_date'
),
anchor AS (
  SELECT ob.account_code, ob.opening_balance
  FROM opening_balances ob
  CROSS JOIN cfg
  WHERE ob.agency_id  = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND ob.as_of_date = cfg.anchor_date
),
ledger AS (
  SELECT
    coa.id                                        AS chart_account_id,
    ROUND(SUM(jl.credit) - SUM(jl.debit), 2)      AS activity_since_anchor,
    MAX(je.entry_date)                            AS last_entry_date,
    COUNT(DISTINCT je.id)                         AS entry_count
  FROM journal_entries je
  JOIN journal_lines jl      ON jl.journal_entry_id = je.id
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  CROSS JOIN cfg
  WHERE je.agency_id  = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND je.entry_date > cfg.anchor_date
    AND coa.account_type = 'liability'
  GROUP BY coa.id
)
SELECT
  ca.agency_id,
  ca.id                                                    AS credit_account_id,
  ca.account_name,
  ca.institution,
  ca.account_type,
  ca.account_number_last4,
  ca.credit_limit,
  ca.interest_rate,
  ca.minimum_payment,
  ca.payment_due_day,
  ca.chart_account_id,
  COALESCE(an.opening_balance, 0)::numeric                 AS balance_anchor,
  COALESCE(l.activity_since_anchor, 0)::numeric            AS activity_since_anchor,
  ROUND(COALESCE(an.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0), 2)
                                                           AS current_balance_derived,
  l.last_entry_date,
  COALESCE(l.entry_count, 0)                               AS entry_count,
  (ca.account_number_last4 IS NULL)                        AS needs_last4,
  (COALESCE(an.opening_balance, 0) + COALESCE(l.activity_since_anchor, 0)) < 0
                                                           AS needs_review
FROM credit_accounts ca
LEFT JOIN chart_of_accounts coa ON coa.id = ca.chart_account_id
LEFT JOIN anchor an             ON an.account_code = coa.account_code
LEFT JOIN ledger l              ON l.chart_account_id = ca.chart_account_id
WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND ca.is_active = true
ORDER BY ca.account_name;
