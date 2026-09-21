-- Tithe pool v2.
--  * ledger_paid_from_code: one home for "which card or bank account paid for
--    this row". learn_gl_rule_from_ledger had it inline; it now calls this, and
--    so do the tithe rules.
--  * Income rules can be narrowed by description and by the account the money
--    landed in (CD interest is only the interest paid into 1071).
--  * Draw rules: transactions matching a rule come out of the pool on their own.
--    Scheduled gifts carry their expected monthly amount.
--  * A draw can be negative (a refund on the tithe card puts money back).
--  * tithe_draw_source says who set it: rule, manual, or excluded. The reconcile
--    only ever touches rule-set draws, so a hand setting is never overwritten.

CREATE OR REPLACE FUNCTION public.ledger_paid_from_code(p_ledger_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT c2.account_code
       FROM ledger l
       JOIN statements s ON s.id = l.statement_id
       JOIN accounts a ON a.id = s.account_id
       JOIN chart_of_accounts c2 ON c2.id = a.chart_account_id
      WHERE l.id = p_ledger_id),
    (SELECT c2.account_code
       FROM ledger l
       JOIN cash_register_preliminary c ON c.id = l.cash_register_id
       JOIN accounts a ON (a.account_number_last4 = c.account_last4
                        OR c.account_last4 = ANY(a.alternate_last4s))
       JOIN chart_of_accounts c2 ON c2.id = a.chart_account_id
      WHERE l.id = p_ledger_id AND a.is_active = TRUE
      LIMIT 1)
  );
$$;

COMMENT ON FUNCTION public.ledger_paid_from_code(uuid) IS
  'The chart code of the card or bank account a ledger row moved through, from its statement line or, before the statement arrives, its cash register row.';


CREATE OR REPLACE FUNCTION public.learn_gl_rule_from_ledger(
  p_ledger_id uuid,
  p_actor text DEFAULT 'pnl_reclassify'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency uuid; v_desc text; v_account_id uuid;
  v_debit numeric; v_credit numeric;
  v_code text; v_entity uuid; v_type text; v_acct_name text;
  v_src_code text; v_direction text; v_pattern text;
  v_existing uuid; v_rule_id uuid; v_action text; v_rule_name text;
BEGIN
  SELECT l.agency_id, l.description, l.account_id, COALESCE(l.debit, 0), COALESCE(l.credit, 0)
    INTO v_agency, v_desc, v_account_id, v_debit, v_credit
  FROM ledger l WHERE l.id = p_ledger_id;

  IF v_agency IS NULL THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'ledger_row_not_found');
  END IF;

  SELECT coa.account_code, coa.business_entity_id, coa.account_type, coa.account_name
    INTO v_code, v_entity, v_type, v_acct_name
  FROM chart_of_accounts coa WHERE coa.id = v_account_id;

  IF v_code IS NULL THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'account_not_found');
  END IF;

  IF v_code IN ('0002', '0003', '0004') OR v_acct_name ILIKE '*Unclassified%' THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'target_is_unclassified');
  END IF;

  v_pattern := gl_pattern_from_description(v_desc);
  IF v_pattern IS NULL THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'description_too_generic');
  END IF;

  v_src_code := ledger_paid_from_code(p_ledger_id);

  v_direction := CASE WHEN v_debit > 0 THEN 'debit'
                      WHEN v_credit > 0 THEN 'credit'
                      ELSE 'both' END;

  SELECT r.id INTO v_existing
  FROM gl_classification_rules r
  WHERE r.agency_id = v_agency
    AND r.is_active = TRUE
    AND r.debit_account_code <> '__SKIP__'
    AND r.match_payee_regex IS NOT NULL
    AND v_desc ~* r.match_payee_regex
    AND r.match_source_account IS NOT DISTINCT FROM v_src_code
    AND (r.match_direction IS NULL OR r.match_direction IN (v_direction, 'both'))
    AND (r.match_amount_min IS NULL OR GREATEST(v_debit, v_credit) >= r.match_amount_min)
    AND (r.match_amount_max IS NULL OR GREATEST(v_debit, v_credit) <= r.match_amount_max)
  ORDER BY r.match_priority ASC NULLS LAST, r.historical_uses DESC NULLS LAST
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    UPDATE gl_classification_rules
       SET debit_account_code  = CASE WHEN v_direction = 'credit' THEN debit_account_code  ELSE v_code END,
           credit_account_code = CASE WHEN v_direction = 'credit' THEN v_code ELSE credit_account_code END,
           target_business_entity_id = v_entity,
           override_reason = 'Repointed from the P&L on '
                             || to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD')
                             || ' by ' || p_actor || ' to ' || v_code || ' ' || v_acct_name,
           updated_at = now()
     WHERE id = v_existing
    RETURNING id INTO v_rule_id;
    v_action := 'updated';
  ELSE
    v_rule_name := 'From the P&L: ' || left(regexp_replace(coalesce(v_desc, ''), '\s+', ' ', 'g'), 60)
                   || ' -> ' || v_code || ' ' || v_acct_name;
    INSERT INTO gl_classification_rules (
      agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
      debit_account_code, credit_account_code, target_business_entity_id, confidence, source, rule_scope, is_active
    ) VALUES (
      v_agency, v_rule_name, 55, v_pattern, v_src_code, v_direction,
      CASE WHEN v_direction = 'credit' THEN '__SOURCE__' ELSE v_code END,
      CASE WHEN v_direction = 'credit' THEN v_code ELSE '__SOURCE__' END,
      v_entity, 'high', p_actor, 'both', TRUE
    )
    RETURNING id INTO v_rule_id;
    v_action := 'created';
  END IF;

  RETURN jsonb_build_object('learned', true, 'action', v_action, 'rule_id', v_rule_id,
    'pattern', v_pattern, 'paid_from_account', v_src_code, 'account_code', v_code, 'account_name', v_acct_name);
END;
$$;


-- income rules can be narrowed
ALTER TABLE public.tithe_pool_rules ADD COLUMN IF NOT EXISTS match_payee_regex text;
ALTER TABLE public.tithe_pool_rules ADD COLUMN IF NOT EXISTS match_source_account text;


-- draw rules
CREATE TABLE IF NOT EXISTS public.tithe_draw_rules (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  rule_name                text NOT NULL,
  priority                 integer NOT NULL DEFAULT 100,
  match_payee_regex        text,
  match_source_account     text,
  is_scheduled             boolean NOT NULL DEFAULT false,
  expected_monthly_amount  numeric(14,2),
  effective_from           date NOT NULL DEFAULT '2026-01-01',
  effective_to             date,
  is_active                boolean NOT NULL DEFAULT true,
  notes                    text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CHECK (match_payee_regex IS NOT NULL OR match_source_account IS NOT NULL),
  CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

COMMENT ON TABLE public.tithe_draw_rules IS
  'Transactions that come out of the tithe pool on their own. Scheduled gifts carry their expected monthly amount; allotments like in-kind giving are not scheduled but still have a monthly figure.';

ALTER TABLE public.tithe_draw_rules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tithe_draw_rules_admin_all ON public.tithe_draw_rules;
CREATE POLICY tithe_draw_rules_admin_all ON public.tithe_draw_rules
  FOR ALL USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tithe_draw_rules TO authenticated, anon;


-- who set the draw, and which rule
ALTER TABLE public.ledger ADD COLUMN IF NOT EXISTS tithe_draw_source text;
ALTER TABLE public.ledger ADD COLUMN IF NOT EXISTS tithe_draw_rule_id uuid REFERENCES public.tithe_draw_rules(id) ON DELETE SET NULL;
ALTER TABLE public.ledger DROP CONSTRAINT IF EXISTS ledger_tithe_draw_source_valid;
ALTER TABLE public.ledger ADD CONSTRAINT ledger_tithe_draw_source_valid
  CHECK (tithe_draw_source IS NULL OR tithe_draw_source IN ('rule','manual','excluded'));
ALTER TABLE public.ledger DROP CONSTRAINT IF EXISTS ledger_tithe_draw_amount_positive;
ALTER TABLE public.ledger DROP CONSTRAINT IF EXISTS ledger_tithe_draw_amount_nonzero;
ALTER TABLE public.ledger ADD CONSTRAINT ledger_tithe_draw_amount_nonzero
  CHECK (tithe_draw_amount IS NULL OR tithe_draw_amount <> 0);

COMMENT ON COLUMN public.ledger.tithe_draw_source IS
  'rule = set by a tithe draw rule and kept current by tithe_pool_reconcile. manual = set by hand, never touched by the reconcile. excluded = marked by hand as not from the pool, so no rule may claim it.';


-- the reconcile now handles money in and money out
CREATE OR REPLACE FUNCTION public.tithe_pool_reconcile(
  p_agency_id uuid,
  p_ledger_ids uuid[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_added int := 0; v_updated int := 0; v_removed int := 0;
  v_draws_set int := 0; v_draws_cleared int := 0;
BEGIN
  -- ── money in ──
  CREATE TEMP TABLE _tithe_should (
    ledger_id uuid, rule_id uuid, entry_date date,
    income_amount numeric(14,2), percent numeric(7,4), amount numeric(14,2), description text
  ) ON COMMIT DROP;

  INSERT INTO _tithe_should
  SELECT l.id, r.id, l.entry_date,
         round(ledger_pnl_amount(l.debit, l.credit, coa.account_type, l.source), 2),
         r.percent,
         round(ledger_pnl_amount(l.debit, l.credit, coa.account_type, l.source) * r.percent / 100.0, 2),
         r.rule_name || ' — ' || r.percent || '% set aside'
  FROM ledger l
  JOIN chart_of_accounts coa ON coa.id = l.account_id
  JOIN tithe_pool_rules r
    ON r.agency_id = l.agency_id
   AND r.income_account_id = l.account_id
   AND r.is_active = TRUE
   AND l.entry_date >= r.effective_from
   AND (r.effective_to IS NULL OR l.entry_date <= r.effective_to)
   AND (r.match_payee_regex IS NULL OR l.description ~* r.match_payee_regex)
   AND (r.match_source_account IS NULL OR r.match_source_account = ledger_paid_from_code(l.id))
  WHERE l.agency_id = p_agency_id
    AND coa.account_type = 'income'
    AND (p_ledger_ids IS NULL OR l.id = ANY(p_ledger_ids))
    AND ledger_pnl_amount(l.debit, l.credit, coa.account_type, l.source) > 0;

  WITH gone AS (
    DELETE FROM tithe_pool_entries e
    WHERE e.agency_id = p_agency_id AND e.direction = 'accrual'
      AND (p_ledger_ids IS NULL OR e.source_ledger_id = ANY(p_ledger_ids))
      AND NOT EXISTS (SELECT 1 FROM _tithe_should s
                      WHERE s.ledger_id = e.source_ledger_id AND s.rule_id = e.rule_id)
    RETURNING 1)
  SELECT count(*) INTO v_removed FROM gone;

  WITH fixed AS (
    UPDATE tithe_pool_entries e
       SET amount = s.amount, income_amount = s.income_amount, percent_applied = s.percent,
           entry_date = s.entry_date, description = s.description
      FROM _tithe_should s
     WHERE e.agency_id = p_agency_id AND e.direction = 'accrual'
       AND e.source_ledger_id = s.ledger_id AND e.rule_id = s.rule_id
       AND (e.amount IS DISTINCT FROM s.amount OR e.income_amount IS DISTINCT FROM s.income_amount
         OR e.percent_applied IS DISTINCT FROM s.percent OR e.entry_date IS DISTINCT FROM s.entry_date
         OR e.description IS DISTINCT FROM s.description)
    RETURNING 1)
  SELECT count(*) INTO v_updated FROM fixed;

  WITH added AS (
    INSERT INTO tithe_pool_entries (agency_id, entry_date, direction, amount, description,
                                    source_ledger_id, rule_id, income_amount, percent_applied, created_by)
    SELECT p_agency_id, s.entry_date, 'accrual', s.amount, s.description,
           s.ledger_id, s.rule_id, s.income_amount, s.percent, 'tithe_pool_reconcile'
    FROM _tithe_should s
    WHERE s.amount > 0
      AND NOT EXISTS (SELECT 1 FROM tithe_pool_entries e
                      WHERE e.source_ledger_id = s.ledger_id AND e.rule_id = s.rule_id AND e.direction = 'accrual')
    RETURNING 1)
  SELECT count(*) INTO v_added FROM added;

  DROP TABLE _tithe_should;

  -- ── money out ──
  CREATE TEMP TABLE _draw_should (ledger_id uuid, rule_id uuid, amount numeric(14,2)) ON COMMIT DROP;

  INSERT INTO _draw_should
  SELECT DISTINCT ON (l.id) l.id, d.id,
         round(COALESCE(l.debit,0) - COALESCE(l.credit,0), 2)
  FROM ledger l
  JOIN chart_of_accounts coa ON coa.id = l.account_id
  JOIN tithe_draw_rules d
    ON d.agency_id = l.agency_id AND d.is_active = TRUE
   AND l.entry_date >= d.effective_from
   AND (d.effective_to IS NULL OR l.entry_date <= d.effective_to)
   AND (d.match_payee_regex IS NULL OR l.description ~* d.match_payee_regex)
   AND (d.match_source_account IS NULL OR d.match_source_account = ledger_paid_from_code(l.id))
  WHERE l.agency_id = p_agency_id
    AND coa.account_type = 'expense'
    AND (p_ledger_ids IS NULL OR l.id = ANY(p_ledger_ids))
    AND COALESCE(l.tithe_draw_source, 'rule') = 'rule'
    AND round(COALESCE(l.debit,0) - COALESCE(l.credit,0), 2) <> 0
  ORDER BY l.id, d.priority, d.created_at;

  WITH cleared AS (
    UPDATE ledger l
       SET tithe_draw_amount = NULL, tithe_draw_source = NULL, tithe_draw_rule_id = NULL
     WHERE l.agency_id = p_agency_id
       AND l.tithe_draw_source = 'rule'
       AND (p_ledger_ids IS NULL OR l.id = ANY(p_ledger_ids))
       AND NOT EXISTS (SELECT 1 FROM _draw_should s WHERE s.ledger_id = l.id)
    RETURNING 1)
  SELECT count(*) INTO v_draws_cleared FROM cleared;

  WITH setd AS (
    UPDATE ledger l
       SET tithe_draw_amount = s.amount, tithe_draw_source = 'rule', tithe_draw_rule_id = s.rule_id
      FROM _draw_should s
     WHERE l.id = s.ledger_id
       AND (l.tithe_draw_amount IS DISTINCT FROM s.amount
         OR l.tithe_draw_source IS DISTINCT FROM 'rule'
         OR l.tithe_draw_rule_id IS DISTINCT FROM s.rule_id)
    RETURNING 1)
  SELECT count(*) INTO v_draws_set FROM setd;

  DROP TABLE _draw_should;

  RETURN jsonb_build_object('set_asides_added', v_added, 'set_asides_updated', v_updated,
                            'set_asides_removed', v_removed,
                            'draws_set', v_draws_set, 'draws_cleared', v_draws_cleared);
END;
$$;


CREATE OR REPLACE FUNCTION public.tg_ledger_tithe_pool_accrue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r record;
BEGIN
  -- the reconcile writes back to ledger; do not react to our own writes
  IF pg_trigger_depth() > 1 THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT c.agency_id, array_agg(c.id) AS ids
    FROM changed_rows c
    WHERE c.agency_id IS NOT NULL
    GROUP BY c.agency_id
  LOOP
    IF EXISTS (SELECT 1 FROM tithe_pool_rules t WHERE t.agency_id = r.agency_id AND t.is_active)
       OR EXISTS (SELECT 1 FROM tithe_draw_rules d WHERE d.agency_id = r.agency_id AND d.is_active) THEN
      PERFORM tithe_pool_reconcile(r.agency_id, r.ids);
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;


-- scheduled gifts: expected vs actually given, by month
CREATE OR REPLACE VIEW public.v_tithe_giving_by_month AS
WITH months AS (
  SELECT generate_series('2026-01-01'::date, date_trunc('month', now() AT TIME ZONE 'America/Chicago')::date, '1 month')::date AS month
)
SELECT d.agency_id, m.month, d.id AS rule_id, d.rule_name, d.is_scheduled,
       d.expected_monthly_amount,
       COALESCE(round(sum(l.tithe_draw_amount), 2), 0) AS given
FROM tithe_draw_rules d
CROSS JOIN months m
LEFT JOIN ledger l
  ON l.tithe_draw_rule_id = d.id
 AND date_trunc('month', l.entry_date)::date = m.month
WHERE d.is_active
  AND m.month >= date_trunc('month', d.effective_from)::date
GROUP BY d.agency_id, m.month, d.id, d.rule_name, d.is_scheduled, d.expected_monthly_amount;

ALTER VIEW public.v_tithe_giving_by_month SET (security_invoker = on);
GRANT SELECT ON public.v_tithe_giving_by_month TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.ledger_paid_from_code(uuid) TO authenticated, anon;
