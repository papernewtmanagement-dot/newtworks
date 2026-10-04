-- 2026-10-04 Peter: Richard's $700 booked automatically each month (pausable from Automations),
-- household refunds/credits -> 8600 Non-taxable Income, stop tithing 8600, office property tax
-- gets its own account under Dues & Licenses.
BEGIN;

-- 1. Business Property Tax account, a sub-account of agency 6710 Dues & Licenses
DROP TRIGGER IF EXISTS lock_chart_of_accounts ON public.chart_of_accounts;
DROP TRIGGER IF EXISTS lock_account_master_codes ON public.account_master_codes;
INSERT INTO public.account_master_codes (agency_id, code, name, account_type, account_subtype, code_kind, description)
SELECT agency_id, '6711', 'Business Property Tax', 'expense', 'licensing', code_kind,
       'County tax on business personal property (office furniture and equipment). Sits under Dues & Licenses.'
FROM public.account_master_codes WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND code='6710'
ON CONFLICT DO NOTHING;
INSERT INTO public.chart_of_accounts (agency_id, account_code, account_name, account_type, account_subtype, parent_account_id, is_active, is_system, business_entity_id, section_label_override, description)
SELECT agency_id, '6711', 'Business Property Tax', 'expense', 'licensing', id, true, false, business_entity_id, section_label_override,
       'County tax on the office''s business personal property. Under Dues & Licenses (Peter 2026-10-04).'
FROM public.chart_of_accounts WHERE id='4fe6d775-a5cd-453e-8f29-990ecba3a970'
  AND NOT EXISTS (SELECT 1 FROM public.chart_of_accounts WHERE account_code='6711' AND business_entity_id='b2222222-2222-2222-2222-222222222222');
UPDATE public.account_master_codes SET name='Non-taxable Income', description='All non-taxable money in: gifts, adoption stipend, refunds and credits, card rewards.', updated_at=now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND code='8600';
CREATE TRIGGER lock_chart_of_accounts BEFORE INSERT OR DELETE OR UPDATE ON public.chart_of_accounts FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();
CREATE TRIGGER lock_account_master_codes BEFORE INSERT OR DELETE OR UPDATE ON public.account_master_codes FOR EACH ROW EXECUTE FUNCTION block_chart_of_accounts_writes();

UPDATE public.gl_classification_rules SET debit_account_code='6711', credit_account_code='6711',
  override_reason=override_reason||' | 2026-10-04 Peter: own account under Dues & Licenses (6711).', updated_at=now()
WHERE match_statement_id='d52fa3fc-e2e6-42f4-9ef5-dc2467ecad33';
INSERT INTO public.ledger_backfill_20260926 SELECT l.* FROM public.ledger l WHERE l.statement_id='d52fa3fc-e2e6-42f4-9ef5-dc2467ecad33' AND NOT EXISTS (SELECT 1 FROM public.ledger_backfill_20260926 b WHERE b.id=l.id);
DELETE FROM public.ledger WHERE statement_id='d52fa3fc-e2e6-42f4-9ef5-dc2467ecad33';
SELECT public.statement_gl_writer('126794dd-25ff-47d2-a436-724499733365', NULL, NULL, NULL, false, ARRAY['d52fa3fc-e2e6-42f4-9ef5-dc2467ecad33']::uuid[]);

-- 2. Household refunds and credits -> that entity's 8600 Non-taxable Income.
-- Applies to any credit on an expense account of an entity that has an active 8600 (only the
-- household does). Not to gifts (9700, they drive the tithe pool) and not to reversals
-- (entry_type correction), which must net against the row they reverse.
CREATE OR REPLACE FUNCTION public.ledger_household_credits_to_nontaxable()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $f$
DECLARE v_acct record; v_target uuid;
BEGIN
  IF COALESCE(NEW.credit,0) <= COALESCE(NEW.debit,0) OR COALESCE(NEW.entry_type,'') = 'correction' THEN
    RETURN NEW;
  END IF;
  SELECT id, account_code, account_name, account_type, business_entity_id INTO v_acct
  FROM chart_of_accounts WHERE id = NEW.account_id;
  IF v_acct.account_type IS DISTINCT FROM 'expense' OR v_acct.account_code = '9700' THEN
    RETURN NEW;
  END IF;
  SELECT id INTO v_target FROM chart_of_accounts
  WHERE agency_id = NEW.agency_id AND business_entity_id = v_acct.business_entity_id
    AND account_code = '8600' AND is_active
  LIMIT 1;
  IF v_target IS NULL THEN RETURN NEW; END IF;
  NEW.original_account_id   := COALESCE(NEW.original_account_id, v_acct.id);
  NEW.original_account_code := COALESCE(NEW.original_account_code, v_acct.account_code);
  NEW.original_account_name := COALESCE(NEW.original_account_name, v_acct.account_name);
  NEW.account_id := v_target;
  RETURN NEW;
END;
$f$;
DROP TRIGGER IF EXISTS ledger_household_credits_to_nontaxable ON public.ledger;
CREATE TRIGGER ledger_household_credits_to_nontaxable BEFORE INSERT OR UPDATE OF account_id, debit, credit ON public.ledger
  FOR EACH ROW EXECUTE FUNCTION public.ledger_household_credits_to_nontaxable();
INSERT INTO public.ledger_backfill_20260926 SELECT l.* FROM public.ledger l JOIN public.chart_of_accounts c ON c.id=l.account_id
  WHERE c.business_entity_id='b3333333-3333-3333-3333-333333333333' AND c.account_type='expense' AND c.account_code<>'9700' AND l.credit>l.debit
  AND NOT EXISTS (SELECT 1 FROM public.ledger_backfill_20260926 b WHERE b.id=l.id);
UPDATE public.ledger l SET credit = l.credit FROM public.chart_of_accounts c
  WHERE c.id=l.account_id AND c.business_entity_id='b3333333-3333-3333-3333-333333333333' AND c.account_type='expense' AND c.account_code<>'9700' AND l.credit>l.debit;

-- 3. Stop tithing 8600 (Peter 2026-10-04: no tithe on the non-taxable category)
UPDATE public.tithe_pool_rules SET is_active=false,
  notes=COALESCE(notes||' ','')||'Retired 2026-10-04: Peter, no tithe on the non-taxable category.', updated_at=now()
WHERE income_account_id='fe7ce856-6abd-4fa0-a50d-a23ed0897f78';

-- 4. Richard's monthly gift: booked automatically, pausable from Automations.
UPDATE public.gl_classification_rules SET is_active=false,
  override_reason=override_reason||' | 2026-10-04 retired: Richard''s gift is booked automatically each month instead (richard_monthly_gift_book).', updated_at=now()
WHERE id='d8a023a0-dbb8-48bf-9e49-0bfd201ed67d';

CREATE OR REPLACE FUNCTION public.richard_gift_book_month(p_agency_id uuid, p_month date, p_amount numeric DEFAULT 700, p_day int DEFAULT 18)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_month date := date_trunc('month', p_month)::date; v_ref text; v_acct uuid; v_id uuid;
BEGIN
  v_ref := 'RICHARD-GIFT-' || to_char(v_month, 'YYYY-MM');
  IF EXISTS (SELECT 1 FROM ledger WHERE agency_id = p_agency_id AND reference_number = v_ref) THEN
    RETURN jsonb_build_object('booked', false, 'reason', 'already_booked', 'reference', v_ref);
  END IF;
  SELECT id INTO v_acct FROM chart_of_accounts WHERE agency_id = p_agency_id AND account_code = '8600'
    AND business_entity_id = 'b3333333-3333-3333-3333-333333333333' AND is_active LIMIT 1;
  IF v_acct IS NULL THEN RAISE EXCEPTION 'Non-taxable Income account (8600) not found'; END IF;
  INSERT INTO ledger (agency_id, account_id, debit, credit, entry_date, entry_type, source, reference_number,
                      description, memo, classification_status, classified_by, classified_at)
  VALUES (p_agency_id, v_acct, 0, p_amount, v_month + (p_day - 1), 'manual', 'richard_monthly_gift', v_ref,
          format('Richard (Peter''s dad) — monthly gift, %s', to_char(v_month, 'FMMonth YYYY')),
          'Added automatically (Peter 2026-10-04). If it did not come, delete it in Financials.',
          'classified', 'richard_monthly_gift_book', now())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('booked', true, 'reference', v_ref, 'ledger_id', v_id, 'amount', p_amount);
END;
$f$;

CREATE OR REPLACE FUNCTION public.richard_monthly_gift_book(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $f$
DECLARE v_r record; v_month date; v_res jsonb;
BEGIN
  SELECT is_active, input_config INTO v_r FROM automation_recipes WHERE id = p_recipe_id;
  IF NOT COALESCE(v_r.is_active, false) THEN
    RETURN jsonb_build_object('booked', false, 'reason', 'paused');
  END IF;
  v_month := date_trunc('month', (NOW() AT TIME ZONE 'America/Chicago') - INTERVAL '1 day')::date;
  v_res := richard_gift_book_month(p_agency_id, v_month,
             COALESCE((v_r.input_config->>'amount')::numeric, 700),
             COALESCE((v_r.input_config->>'day')::int, 18));
  RETURN v_res || jsonb_build_object('records_processed', CASE WHEN (v_res->>'booked')::boolean THEN 1 ELSE 0 END,
                                     'output_summary', format('Richard gift %s: %s', to_char(v_month,'YYYY-MM'), COALESCE(v_res->>'reason','booked')));
END;
$f$;

INSERT INTO public.automation_recipes (agency_id, recipe_name, recipe_description, trigger_type, composio_action, internal_handler, input_config, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Richard Monthly Gift — $700',
  'Books Richard''s $700 monthly gift into household Non-taxable Income (8600), dated the 18th of the prior month. Runs as part of the 1st-of-month Leslie Goals + Print Sales check-in, which tells Alvi it was added and to delete it in Financials if it did not come. Turn this off to pause it. Peter 2026-10-04.',
  'manual', 'INTERNAL', 'richard_monthly_gift_book', '{"amount":700,"day":18}'::jsonb, true, 'America/Chicago'
WHERE NOT EXISTS (SELECT 1 FROM public.automation_recipes WHERE internal_handler='richard_monthly_gift_book');

-- Backfill Feb-Sep 2026 (Alvi's household sheet: $700 each month Feb-Sep)
SELECT public.richard_gift_book_month('126794dd-25ff-47d2-a436-724499733365', m::date)
FROM generate_series('2026-02-01'::date, '2026-09-01'::date, interval '1 month') m;

COMMIT;
