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
  v_added int := 0;
  v_updated int := 0;
  v_removed int := 0;
BEGIN
  CREATE TEMP TABLE _tithe_should (
    ledger_id uuid,
    rule_id uuid,
    entry_date date,
    income_amount numeric(14,2),
    percent numeric(7,4),
    amount numeric(14,2),
    description text
  ) ON COMMIT DROP;

  INSERT INTO _tithe_should
  SELECT l.id, r.id, l.entry_date,
         round(ledger_pnl_amount(l.debit, l.credit, coa.account_type, l.source), 2),
         r.percent,
         round(ledger_pnl_amount(l.debit, l.credit, coa.account_type, l.source) * r.percent / 100.0, 2),
         coalesce(coa.account_name, 'Income') || ' — ' || r.percent || '% set aside'
  FROM ledger l
  JOIN chart_of_accounts coa ON coa.id = l.account_id
  JOIN tithe_pool_rules r
    ON r.agency_id = l.agency_id
   AND r.income_account_id = l.account_id
   AND r.is_active = TRUE
   AND l.entry_date >= r.effective_from
   AND (r.effective_to IS NULL OR l.entry_date <= r.effective_to)
  WHERE l.agency_id = p_agency_id
    AND coa.account_type = 'income'
    AND (p_ledger_ids IS NULL OR l.id = ANY(p_ledger_ids))
    AND ledger_pnl_amount(l.debit, l.credit, coa.account_type, l.source) > 0;

  WITH gone AS (
    DELETE FROM tithe_pool_entries e
    WHERE e.agency_id = p_agency_id
      AND e.direction = 'accrual'
      AND (p_ledger_ids IS NULL OR e.source_ledger_id = ANY(p_ledger_ids))
      AND NOT EXISTS (
        SELECT 1 FROM _tithe_should s
        WHERE s.ledger_id = e.source_ledger_id AND s.rule_id = e.rule_id
      )
    RETURNING 1
  )
  SELECT count(*) INTO v_removed FROM gone;

  WITH fixed AS (
    UPDATE tithe_pool_entries e
    SET amount = s.amount,
        income_amount = s.income_amount,
        percent_applied = s.percent,
        entry_date = s.entry_date,
        description = s.description
    FROM _tithe_should s
    WHERE e.agency_id = p_agency_id
      AND e.direction = 'accrual'
      AND e.source_ledger_id = s.ledger_id
      AND e.rule_id = s.rule_id
      AND (e.amount IS DISTINCT FROM s.amount
        OR e.income_amount IS DISTINCT FROM s.income_amount
        OR e.percent_applied IS DISTINCT FROM s.percent
        OR e.entry_date IS DISTINCT FROM s.entry_date)
    RETURNING 1
  )
  SELECT count(*) INTO v_updated FROM fixed;

  WITH added AS (
    INSERT INTO tithe_pool_entries (
      agency_id, entry_date, direction, amount, description,
      source_ledger_id, rule_id, income_amount, percent_applied, created_by
    )
    SELECT p_agency_id, s.entry_date, 'accrual', s.amount, s.description,
           s.ledger_id, s.rule_id, s.income_amount, s.percent, 'tithe_pool_reconcile'
    FROM _tithe_should s
    WHERE NOT EXISTS (
      SELECT 1 FROM tithe_pool_entries e
      WHERE e.source_ledger_id = s.ledger_id AND e.rule_id = s.rule_id AND e.direction = 'accrual'
    )
      AND s.amount > 0
    RETURNING 1
  )
  SELECT count(*) INTO v_added FROM added;

  DROP TABLE _tithe_should;

  RETURN jsonb_build_object('added', v_added, 'updated', v_updated, 'removed', v_removed);
END;
$$;

COMMENT ON FUNCTION public.tithe_pool_reconcile(uuid, uuid[]) IS
  'Brings tithe pool set-asides in line with the income on the books. Idempotent: adds what is missing, corrects what changed, removes what no longer applies.';


CREATE OR REPLACE FUNCTION public.tg_ledger_tithe_pool_accrue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency uuid;
  v_ids uuid[];
BEGIN
  SELECT array_agg(id), min(agency_id) INTO v_ids, v_agency FROM changed_rows;
  IF v_ids IS NULL OR v_agency IS NULL THEN
    RETURN NULL;
  END IF;
  -- no percentages set yet means nothing to do, and costs one cheap lookup
  IF NOT EXISTS (SELECT 1 FROM tithe_pool_rules WHERE agency_id = v_agency AND is_active) THEN
    RETURN NULL;
  END IF;
  PERFORM tithe_pool_reconcile(v_agency, v_ids);
  RETURN NULL;
END;
$$;

-- Statement-level with a transition table. Postgres will not allow a column
-- list alongside a transition table, so the UPDATE trigger fires on any update
-- and the function itself decides there is nothing to do.
DROP TRIGGER IF EXISTS ledger_tithe_pool_accrue_ins ON public.ledger;
CREATE TRIGGER ledger_tithe_pool_accrue_ins
AFTER INSERT ON public.ledger
REFERENCING NEW TABLE AS changed_rows
FOR EACH STATEMENT EXECUTE FUNCTION public.tg_ledger_tithe_pool_accrue();

DROP TRIGGER IF EXISTS ledger_tithe_pool_accrue_upd ON public.ledger;
CREATE TRIGGER ledger_tithe_pool_accrue_upd
AFTER UPDATE ON public.ledger
REFERENCING NEW TABLE AS changed_rows
FOR EACH STATEMENT EXECUTE FUNCTION public.tg_ledger_tithe_pool_accrue();


CREATE OR REPLACE VIEW public.v_tithe_pool_activity AS
SELECT
  e.agency_id,
  e.entry_date,
  CASE WHEN e.direction = 'accrual' THEN 'Set aside' ELSE 'Adjustment' END AS kind,
  e.amount AS into_pool,
  0::numeric AS out_of_pool,
  e.description,
  e.source_ledger_id AS ledger_id,
  NULL::text AS account_name,
  e.income_amount,
  e.percent_applied
FROM public.tithe_pool_entries e
UNION ALL
SELECT
  l.agency_id,
  l.entry_date,
  'Given' AS kind,
  0::numeric AS into_pool,
  l.tithe_draw_amount AS out_of_pool,
  l.description,
  l.id AS ledger_id,
  coa.account_name,
  NULL::numeric,
  NULL::numeric
FROM public.ledger l
JOIN public.chart_of_accounts coa ON coa.id = l.account_id
WHERE l.tithe_draw_amount IS NOT NULL;

CREATE OR REPLACE VIEW public.v_tithe_pool_balance AS
SELECT
  agency_id,
  round(sum(into_pool), 2)                     AS set_aside_total,
  round(sum(out_of_pool), 2)                   AS given_total,
  round(sum(into_pool) - sum(out_of_pool), 2)  AS available
FROM public.v_tithe_pool_activity
GROUP BY agency_id;

ALTER VIEW public.v_tithe_pool_activity SET (security_invoker = on);
ALTER VIEW public.v_tithe_pool_balance  SET (security_invoker = on);


ALTER TABLE public.tithe_pool_rules   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tithe_pool_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tithe_pool_rules_admin_read   ON public.tithe_pool_rules;
DROP POLICY IF EXISTS tithe_pool_rules_admin_insert ON public.tithe_pool_rules;
DROP POLICY IF EXISTS tithe_pool_rules_admin_update ON public.tithe_pool_rules;
DROP POLICY IF EXISTS tithe_pool_rules_admin_delete ON public.tithe_pool_rules;

CREATE POLICY tithe_pool_rules_admin_read ON public.tithe_pool_rules
  FOR SELECT USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY tithe_pool_rules_admin_insert ON public.tithe_pool_rules
  FOR INSERT WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY tithe_pool_rules_admin_update ON public.tithe_pool_rules
  FOR UPDATE USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
          WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY tithe_pool_rules_admin_delete ON public.tithe_pool_rules
  FOR DELETE USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

DROP POLICY IF EXISTS tithe_pool_entries_admin_read   ON public.tithe_pool_entries;
DROP POLICY IF EXISTS tithe_pool_entries_admin_insert ON public.tithe_pool_entries;
DROP POLICY IF EXISTS tithe_pool_entries_admin_update ON public.tithe_pool_entries;
DROP POLICY IF EXISTS tithe_pool_entries_admin_delete ON public.tithe_pool_entries;

CREATE POLICY tithe_pool_entries_admin_read ON public.tithe_pool_entries
  FOR SELECT USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY tithe_pool_entries_admin_insert ON public.tithe_pool_entries
  FOR INSERT WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY tithe_pool_entries_admin_update ON public.tithe_pool_entries
  FOR UPDATE USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin())
          WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());
CREATE POLICY tithe_pool_entries_admin_delete ON public.tithe_pool_entries
  FOR DELETE USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND is_agency_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.tithe_pool_rules   TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tithe_pool_entries TO authenticated, anon;
GRANT SELECT ON public.v_tithe_pool_activity TO authenticated, anon;
GRANT SELECT ON public.v_tithe_pool_balance  TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.tithe_pool_reconcile(uuid, uuid[]) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.ledger_pnl_amount(numeric, numeric, text, text) TO authenticated, anon;
