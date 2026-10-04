-- 2026-10-04 (2) Peter: every entity's refunds/credits -> personal 8600 Non-taxable Income; adoption
-- stipend tithed again (not HIPP refunds); tithe base nets State Farm chargebacks so it equals 12% of the
-- gross comp statement; PaperNewt sales & use tax tracked with a due-date reminder to Alvi.
BEGIN;

-- 1. Refunds and credits from every entity -> personal 8600 (replaces the household-only trigger)
DROP TRIGGER IF EXISTS ledger_household_credits_to_nontaxable ON public.ledger;
DROP FUNCTION IF EXISTS public.ledger_household_credits_to_nontaxable();
CREATE OR REPLACE FUNCTION public.ledger_credits_to_nontaxable()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $f$
-- Peter 2026-10-04: all refunds and credits, any entity, are personal non-taxable income.
-- Money-in from card/bank lines only (statement and bank-alert writers). Left alone: reversals
-- (entry_type correction, they must net against the row they reverse), payroll/comp allocations,
-- gifts (9700) and refunds on the Discover tithe card (2171), which are negative gifts for the tithe pool.
DECLARE v_acct record; v_target uuid; v_paid_from text;
BEGIN
  IF COALESCE(NEW.credit,0) <= COALESCE(NEW.debit,0)
     OR COALESCE(NEW.entry_type,'') = 'correction'
     OR COALESCE(NEW.source,'') NOT IN ('statement_gl_writer','cash_register_gl_writer') THEN
    RETURN NEW;
  END IF;
  SELECT id, account_code, account_name, account_type INTO v_acct FROM chart_of_accounts WHERE id = NEW.account_id;
  IF v_acct.account_type IS DISTINCT FROM 'expense' OR v_acct.account_code = '9700' THEN RETURN NEW; END IF;
  IF NEW.statement_id IS NOT NULL THEN
    SELECT c.account_code INTO v_paid_from FROM statements s JOIN accounts a ON a.id = s.account_id
      JOIN chart_of_accounts c ON c.id = a.chart_account_id WHERE s.id = NEW.statement_id;
    IF v_paid_from = '2171' THEN RETURN NEW; END IF;
  END IF;
  SELECT id INTO v_target FROM chart_of_accounts
  WHERE agency_id = NEW.agency_id AND account_code = '8600' AND is_active
    AND business_entity_id = 'b3333333-3333-3333-3333-333333333333' LIMIT 1;
  IF v_target IS NULL THEN RETURN NEW; END IF;
  NEW.original_account_id   := COALESCE(NEW.original_account_id, v_acct.id);
  NEW.original_account_code := COALESCE(NEW.original_account_code, v_acct.account_code);
  NEW.original_account_name := COALESCE(NEW.original_account_name, v_acct.account_name);
  NEW.account_id := v_target;
  RETURN NEW;
END;
$f$;
CREATE TRIGGER ledger_credits_to_nontaxable BEFORE INSERT OR UPDATE OF account_id, debit, credit ON public.ledger
  FOR EACH ROW EXECUTE FUNCTION public.ledger_credits_to_nontaxable();
INSERT INTO public.ledger_backfill_20260926 SELECT l.* FROM public.ledger l JOIN public.chart_of_accounts c ON c.id=l.account_id
  WHERE c.account_type='expense' AND c.account_code<>'9700' AND l.credit>l.debit AND l.source IN ('statement_gl_writer','cash_register_gl_writer')
  AND NOT EXISTS (SELECT 1 FROM public.ledger_backfill_20260926 b WHERE b.id=l.id);
UPDATE public.ledger l SET credit = l.credit FROM public.chart_of_accounts c
  WHERE c.id=l.account_id AND c.account_type='expense' AND c.account_code<>'9700' AND l.credit>l.debit
  AND l.source IN ('statement_gl_writer','cash_register_gl_writer');

-- 2. Adoption stipend tithed again (HIPP refunds and the other 8600 money are not)
UPDATE public.tithe_pool_rules SET is_active=true, match_payee_regex='(?i)FAMILY\s+PROTCT|POST\s+ADOPTION',
  notes='Adoption stipend only (Peter 2026-10-04: the stipend is still tithed; the rest of 8600 is not).', updated_at=now()
WHERE id='871a504f-27b3-4da7-ae78-22925a85d096';
UPDATE public.tithe_pool_rules SET is_active=true, updated_at=now()
WHERE income_account_id='fe7ce856-6abd-4fa0-a50d-a23ed0897f78' AND rule_name LIKE 'Adoption stipend — $250%';

-- 3. Tithe base = 12% of the gross comp statement, chargebacks included (they were being skipped)
CREATE OR REPLACE FUNCTION public.tithe_pool_reconcile(p_agency_id uuid, p_ledger_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_added int := 0; v_updated int := 0; v_removed int := 0;
  v_draws_set int := 0; v_draws_cleared int := 0;
BEGIN
  PERFORM set_config('newtworks.tithe_reconciling', 'on', true);
  -- ── money in ──
  -- 2026-10-04: negative lines on a tithed income account (State Farm commission chargebacks) now
  -- count as negative set-asides, so the base is the gross comp statement total, which is what
  -- Alvi's 12% matches to the penny. Before this only positive lines were tithed.
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
    AND ledger_pnl_amount(l.debit, l.credit, coa.account_type, l.source) <> 0;

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
    WHERE s.amount <> 0
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
   AND (d.match_account_code IS NULL OR d.match_account_code = coa.account_code)
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
  PERFORM set_config('newtworks.tithe_reconciling', 'off', true);

  RETURN jsonb_build_object('set_asides_added', v_added, 'set_asides_updated', v_updated,
                            'set_asides_removed', v_removed,
                            'draws_set', v_draws_set, 'draws_cleared', v_draws_cleared);
END;
$function$;

-- 4. PaperNewt sales & use tax: what is owed per tax year, and the reminder to Alvi.
-- Owed = PaperNewt 2050 Sales Tax Payable lines dated in the year (sales tax from PayPal invoices,
-- source paypal_print_sales; use tax, source use_tax). Paid = Texas Comptroller WebFile payments on any
-- bank statement during the next year (PaperNewt files yearly; the return is due Jan 20).
CREATE OR REPLACE FUNCTION public.papernewt_sales_tax_status(p_agency_id uuid)
RETURNS TABLE (tax_year int, sales_tax numeric, use_tax numeric, total_due numeric, paid numeric, balance numeric, due_date date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $f$
  WITH owed AS (
    SELECT extract(year FROM l.entry_date)::int y,
           sum(CASE WHEN l.source = 'use_tax' THEN 0 ELSE l.credit - l.debit END) s,
           sum(CASE WHEN l.source = 'use_tax' THEN l.credit - l.debit ELSE 0 END) u
    FROM ledger l JOIN chart_of_accounts c ON c.id = l.account_id
    WHERE l.agency_id = p_agency_id AND c.account_code = '2050'
      AND c.business_entity_id = 'b1111111-1111-1111-1111-111111111111'
    GROUP BY 1),
  pay AS (
    SELECT extract(year FROM s.transaction_date)::int - 1 y, sum(abs(s.amount)) p
    FROM statements s
    WHERE s.agency_id = p_agency_id AND s.superseded_by IS NULL AND s.amount < 0
      AND s.description ~* 'WEBFILE|COMPTROLLER'
    GROUP BY 1)
  SELECT o.y, round(o.s,2), round(o.u,2), round(o.s + o.u,2), round(COALESCE(p.p,0),2),
         round(o.s + o.u - COALESCE(p.p,0),2), make_date(o.y + 1, 1, 20)
  FROM owed o LEFT JOIN pay p ON p.y = o.y
  WHERE NOT auth_is_family()
  ORDER BY o.y;
$f$;
GRANT EXECUTE ON FUNCTION public.papernewt_sales_tax_status(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.papernewt_sales_tax_reminder(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions' AS $f$
DECLARE v_today date := (NOW() AT TIME ZONE 'America/Chicago')::date; v_row record;
        v_chat bigint; v_uid bigint; v_mention text; v_msg text; v_resp jsonb;
BEGIN
  SELECT * INTO v_row FROM papernewt_sales_tax_status(p_agency_id) t
  WHERE t.tax_year = extract(year FROM v_today)::int - 1;
  IF v_row.tax_year IS NULL OR v_row.balance <= 0 THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'Nothing owed for last year, or already paid');
  END IF;
  SELECT setting_value::bigint INTO v_chat FROM settings WHERE agency_id=p_agency_id AND setting_key='paper_newt_management_group_chat_id';
  SELECT telegram_user_id INTO v_uid FROM team WHERE agency_id=p_agency_id AND id='d7431075-d29f-4833-9503-430945894b04'
    AND COALESCE(is_excluded_paper_newt_bot,false)=false;
  v_mention := CASE WHEN v_uid IS NOT NULL THEN format('<a href="tg://user?id=%s">Alvi</a>', v_uid) ELSE 'Alvi' END;
  v_msg := format(E'%s — PaperNewt''s %s Texas sales and use tax return is %s Jan 20: $%s owed ($%s sales tax + $%s use tax). File and pay on Texas WebFile. It clears in Newtworks once the payment shows on the bank statement.',
                  v_mention, v_row.tax_year, CASE WHEN v_today > make_date(v_row.tax_year+1,1,20) THEN 'PAST DUE since' ELSE 'due' END,
                  to_char(v_row.balance,'FM999,990.00'), to_char(v_row.sales_tax,'FM999,990.00'), to_char(v_row.use_tax,'FM999,990.00'));
  v_resp := paper_newt_send_message(v_chat, v_msg, 'HTML', NULL);
  RETURN jsonb_build_object('records_processed', 1, 'output_summary', format('Sales tax reminder %s: $%s', v_row.tax_year, v_row.balance), 'ok', v_resp->'ok');
END;
$f$;

INSERT INTO public.automation_recipes (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, composio_action, internal_handler, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'PaperNewt Sales Tax Due — Alvi',
  'Jan 5, 15 and 25 at 9am Central: if last year''s PaperNewt Texas sales + use tax is not paid yet, posts in the Paper Newt Management group telling Alvi the amount and that it is due Jan 20 (past due after). Owed comes from PaperNewt 2050 Sales Tax Payable; paid = WebFile payments on bank statements. Peter 2026-10-04.',
  'cron', '0 9 5,15,25 1 *', 'INTERNAL', 'papernewt_sales_tax_reminder', true, 'America/Chicago'
WHERE NOT EXISTS (SELECT 1 FROM public.automation_recipes WHERE internal_handler='papernewt_sales_tax_reminder');

COMMIT;
