-- 2026-10-04 Peter: a tax pool beside the tithe pool, built in the same tables (pool column).
-- Money in: 3% of the gross State Farm comp (what Alvi's tax set-aside does, 1B "for now").
-- Money out: tax payments (personal income tax, home and business property tax, IRS, Texas
-- Comptroller, Florida Dept of Revenue). Starting balance Jan 1: $7,853.55 from the old books (2A).
BEGIN;
ALTER TABLE public.tithe_pool_rules   ADD COLUMN IF NOT EXISTS pool text NOT NULL DEFAULT 'tithe';
ALTER TABLE public.tithe_draw_rules   ADD COLUMN IF NOT EXISTS pool text NOT NULL DEFAULT 'tithe';
ALTER TABLE public.tithe_pool_entries ADD COLUMN IF NOT EXISTS pool text NOT NULL DEFAULT 'tithe';
DO $$ BEGIN
  ALTER TABLE public.tithe_pool_rules   ADD CONSTRAINT tithe_pool_rules_pool_check   CHECK (pool IN ('tithe','tax'));
  ALTER TABLE public.tithe_draw_rules   ADD CONSTRAINT tithe_draw_rules_pool_check   CHECK (pool IN ('tithe','tax'));
  ALTER TABLE public.tithe_pool_entries ADD CONSTRAINT tithe_pool_entries_pool_check CHECK (pool IN ('tithe','tax'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- One active rule per income account per start date, per pool (a comp account now has a tithe rule and a tax rule)
DROP INDEX IF EXISTS public.tithe_pool_rules_one_per_account_period;
CREATE UNIQUE INDEX tithe_pool_rules_one_per_account_period
  ON public.tithe_pool_rules (agency_id, income_account_id, effective_from, pool) WHERE is_active;

-- Each set-aside carries its rule's pool
CREATE OR REPLACE FUNCTION public.tithe_pool_entry_pool_from_rule()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $f$
BEGIN
  IF NEW.rule_id IS NOT NULL THEN
    SELECT pool INTO NEW.pool FROM tithe_pool_rules WHERE id = NEW.rule_id;
  END IF;
  NEW.pool := COALESCE(NEW.pool, 'tithe');
  RETURN NEW;
END; $f$;
DROP TRIGGER IF EXISTS tithe_pool_entry_pool_from_rule ON public.tithe_pool_entries;
CREATE TRIGGER tithe_pool_entry_pool_from_rule BEFORE INSERT OR UPDATE OF rule_id ON public.tithe_pool_entries
  FOR EACH ROW EXECUTE FUNCTION public.tithe_pool_entry_pool_from_rule();

-- Set-aside rules: 3% of every agency comp account the tithe uses
INSERT INTO public.tithe_pool_rules (agency_id, rule_name, income_account_id, percent, effective_from, is_active, notes, pool)
SELECT r.agency_id, 'Tax — ' || r.rule_name, r.income_account_id, 3, '2026-01-01', true,
       '3% of the gross State Farm comp for taxes (Alvi''s tax set-aside; Peter 2026-10-04 1B "for now").', 'tax'
FROM public.tithe_pool_rules r
WHERE r.pool = 'tithe' AND r.rule_name ILIKE 'Agency comp%' AND r.is_active
  AND NOT EXISTS (SELECT 1 FROM public.tithe_pool_rules t WHERE t.pool='tax' AND t.income_account_id = r.income_account_id);

-- Payment rules
INSERT INTO public.tithe_draw_rules (agency_id, rule_name, priority, match_payee_regex, match_account_code, is_scheduled, effective_from, is_active, notes, pool)
SELECT '126794dd-25ff-47d2-a436-724499733365', x.n, x.p, x.rx, x.ac, false, '2026-01-01', true, 'Tax pool payment (Peter 2026-10-04).', 'tax'
FROM (VALUES
  ('Tax — Personal income tax (9900)', 20, NULL, '9900'),
  ('Tax — Home property tax (9910)', 20, NULL, '9910'),
  ('Tax — Business property tax (6711)', 20, NULL, '6711'),
  ('Tax — IRS payments', 25, '(?i)\yIRS\y|USATAX', NULL),
  ('Tax — Texas Comptroller / WebFile', 25, '(?i)WEBFILE|COMPTROLLER', NULL),
  ('Tax — Florida Dept of Revenue', 25, '(?i)DEPT\s+REVENUE', NULL)
) AS x(n, p, rx, ac)
WHERE NOT EXISTS (SELECT 1 FROM public.tithe_draw_rules d WHERE d.rule_name = x.n);

-- Views: activity and balances per pool; the tithe views stay tithe-only
CREATE OR REPLACE VIEW public.v_tithe_pool_activity AS
 SELECT e.agency_id, e.entry_date,
        CASE WHEN e.direction = 'accrual' THEN 'Set aside' ELSE 'Adjustment' END AS kind,
        e.amount AS into_pool, (0)::numeric AS out_of_pool, e.description,
        e.source_ledger_id AS ledger_id, NULL::text AS account_name, e.income_amount, e.percent_applied,
        e.pool
   FROM tithe_pool_entries e
 UNION ALL
 SELECT l.agency_id, l.entry_date,
        CASE WHEN COALESCE(d.pool, 'tithe') = 'tax' THEN 'Paid' ELSE 'Given' END AS kind,
        (0)::numeric AS into_pool, l.tithe_draw_amount AS out_of_pool, l.description,
        l.id AS ledger_id, coa.account_name, NULL::numeric, NULL::numeric,
        COALESCE(d.pool, 'tithe') AS pool
   FROM ledger l
   JOIN chart_of_accounts coa ON coa.id = l.account_id
   LEFT JOIN tithe_draw_rules d ON d.id = l.tithe_draw_rule_id
  WHERE l.tithe_draw_amount IS NOT NULL;

CREATE OR REPLACE VIEW public.v_pool_balance AS
 SELECT agency_id, pool, set_aside_total, given_total, available
   FROM (SELECT agency_id, pool,
                round(sum(into_pool), 2) AS set_aside_total,
                round(sum(out_of_pool), 2) AS given_total,
                round(sum(into_pool) - sum(out_of_pool), 2) AS available
           FROM v_tithe_pool_activity GROUP BY agency_id, pool) b
  WHERE NOT auth_is_family();

CREATE OR REPLACE VIEW public.v_tithe_pool_balance AS
 SELECT agency_id, set_aside_total, given_total, available FROM v_pool_balance WHERE pool = 'tithe';

CREATE OR REPLACE VIEW public.v_tithe_giving_by_month AS
 WITH months AS (
   SELECT (generate_series(('2026-01-01'::date)::timestamp with time zone,
           ((date_trunc('month', (now() AT TIME ZONE 'America/Chicago')))::date)::timestamp with time zone,
           '1 mon'::interval))::date AS month)
 SELECT d.agency_id, m.month, d.id AS rule_id, d.rule_name, d.is_scheduled, d.expected_monthly_amount,
        COALESCE(round(sum(l.tithe_draw_amount), 2), (0)::numeric) AS given
   FROM tithe_draw_rules d
   CROSS JOIN months m
   LEFT JOIN ledger l ON l.tithe_draw_rule_id = d.id
        AND (date_trunc('month', l.entry_date::timestamp with time zone))::date = m.month
  WHERE d.is_active AND d.pool = 'tithe'
    AND m.month >= (date_trunc('month', d.effective_from::timestamp with time zone))::date
  GROUP BY d.agency_id, m.month, d.id, d.rule_name, d.is_scheduled, d.expected_monthly_amount;

-- Starting balance (2A)
INSERT INTO public.tithe_pool_entries (agency_id, entry_date, direction, amount, description, created_by, pool)
SELECT '126794dd-25ff-47d2-a436-724499733365', '2026-01-01', 'adjustment', 7853.55,
  'Tax money carried from 2025 (old books): Alvi''s Mar 1 tax balance 5,348.62 - 2026 Jan-Feb 3% set-asides 3,308.98 - Dec 31 check''s 570.93 (moved Jan 13) + Jan taxes paid from it 6,384.84 (county 6,213.36, WebFile 171.48). Peter 2026-10-04 (2A).',
  'claude_conversation', 'tax'
WHERE NOT EXISTS (SELECT 1 FROM public.tithe_pool_entries WHERE pool='tax' AND direction='adjustment' AND entry_date='2026-01-01');

-- Jan 16 WebFile $171.48 (2025 PaperNewt sales tax) was paid from the tax money, but it was booked
-- against Sales Tax Payable (PN 2050), so no ledger row exists to count as a payment. Recorded here.
INSERT INTO public.tithe_pool_entries (agency_id, entry_date, direction, amount, description, created_by, pool)
SELECT '126794dd-25ff-47d2-a436-724499733365', '2026-01-16', 'adjustment', -171.48,
  'Paid from tax money: Texas WebFile 2025 PaperNewt sales tax (booked to Sales Tax Payable, so no expense row).',
  'claude_conversation', 'tax'
WHERE NOT EXISTS (SELECT 1 FROM public.tithe_pool_entries WHERE pool='tax' AND direction='adjustment' AND entry_date='2026-01-16');

SELECT public.tithe_pool_reconcile('126794dd-25ff-47d2-a436-724499733365', NULL);
COMMIT;
