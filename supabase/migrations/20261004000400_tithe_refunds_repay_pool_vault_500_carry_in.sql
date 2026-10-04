-- 2026-10-04 (3) Peter: tithe refunds go to personal Non-taxable Income and the tithe pool is paid back;
-- "gift" wording dropped for tithe donations; the Apr 17 $500 Venmo from the agency income account was the
-- Vault donation charged on the wrong account; 2025 tithe carried in as a Jan 1 opening line.
BEGIN;
CREATE OR REPLACE FUNCTION public.ledger_credits_to_nontaxable()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $f$
-- Peter 2026-10-04: all refunds and credits, any entity, are personal non-taxable income.
-- Money-in from card/bank lines only (statement and bank-alert writers). Left alone: reversals
-- (entry_type correction, they must net against the row they reverse) and payroll/comp allocations.
-- Tithe refunds (Tithe & Charitable 9700, Discover tithe card 2171) also land here; the tithe pool
-- gets that money back through tithe_pool_reconcile (negative draw on the moved row). Peter 2026-10-04.
DECLARE v_acct record; v_target uuid;
BEGIN
  IF COALESCE(NEW.credit,0) <= COALESCE(NEW.debit,0)
     OR COALESCE(NEW.entry_type,'') = 'correction'
     OR COALESCE(NEW.source,'') NOT IN ('statement_gl_writer','cash_register_gl_writer') THEN
    RETURN NEW;
  END IF;
  SELECT id, account_code, account_name, account_type INTO v_acct FROM chart_of_accounts WHERE id = NEW.account_id;
  IF v_acct.account_type IS DISTINCT FROM 'expense' THEN RETURN NEW; END IF;
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
DROP TRIGGER IF EXISTS ledger_credits_to_nontaxable ON public.ledger;
CREATE TRIGGER ledger_credits_to_nontaxable BEFORE INSERT OR UPDATE OF account_id, debit, credit ON public.ledger
  FOR EACH ROW EXECUTE FUNCTION public.ledger_credits_to_nontaxable();

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
   AND (d.match_account_code IS NULL OR d.match_account_code = COALESCE(l.original_account_code, coa.account_code))
  WHERE l.agency_id = p_agency_id
    -- 2026-10-04: a tithe refund is moved to Non-taxable Income (8600) by ledger_credits_to_nontaxable;
    -- it still matches its draw rule (by its original account or the card it came back on) and counts
    -- as a negative draw, so the tithe pool gets the money back.
    AND (coa.account_type = 'expense'
         OR (coa.account_code = '8600' AND l.original_account_code IS NOT NULL
             AND COALESCE(l.credit,0) > COALESCE(l.debit,0)))
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


UPDATE public.tithe_draw_rules SET rule_name='Any donation booked to Tithe & Charitable', updated_at=now()
WHERE id='7e6fcfcc-c6bb-43e8-804a-ee1cefd5b543';
UPDATE public.gl_classification_rules SET rule_name='One-time: Venmo $1,000 2026-09-17 = tithe donation to people we know (tithe pool, not deductible)', updated_at=now()
WHERE id='db26e818-17fb-4e57-8a1d-e912f6037ab8';

INSERT INTO public.gl_classification_rules (agency_id, rule_name, match_priority, match_statement_id, debit_account_code, credit_account_code, target_business_entity_id, is_active, rule_scope, source, confidence, override_reason)
VALUES ('126794dd-25ff-47d2-a436-724499733365','One-time: Venmo $500 2026-04-17 from the agency income account = Vault tithe donation charged on the wrong account',1,'8e3270b4-2ff1-4434-82e6-a5d322bd6f1b','9700','9700','b3333333-3333-3333-3333-333333333333',true,'statement','claude_conversation','exact','2026-10-04 Peter: the $500 Vault donation was charged on the wrong card; Alvi took it off the 4/15 tithe set-aside.');
INSERT INTO public.ledger_backfill_20260926 SELECT l.* FROM public.ledger l WHERE l.statement_id='8e3270b4-2ff1-4434-82e6-a5d322bd6f1b' AND NOT EXISTS (SELECT 1 FROM public.ledger_backfill_20260926 b WHERE b.id=l.id);
DELETE FROM public.ledger WHERE statement_id='8e3270b4-2ff1-4434-82e6-a5d322bd6f1b';
SELECT public.statement_gl_writer('126794dd-25ff-47d2-a436-724499733365', NULL, NULL, NULL, false, ARRAY['8e3270b4-2ff1-4434-82e6-a5d322bd6f1b']::uuid[]);

INSERT INTO public.tithe_pool_entries (agency_id, entry_date, direction, amount, description, created_by)
SELECT '126794dd-25ff-47d2-a436-724499733365', '2026-01-01', 'adjustment', 5975.63,
  'Carried from 2025 (old books): Alvi''s balance owed 11,947.13 + Dec 31 check''s 12% 2,283.70 (moved Jan 13) - 8,255.20 Discover bills for tithe donations charged in Dec 2025. Peter 2026-10-04 (decision 2A).',
  'claude_conversation'
WHERE NOT EXISTS (SELECT 1 FROM public.tithe_pool_entries WHERE direction='adjustment' AND entry_date='2026-01-01' AND description LIKE 'Carried from 2025%');

SELECT public.tithe_pool_reconcile('126794dd-25ff-47d2-a436-724499733365', NULL);
COMMIT;
