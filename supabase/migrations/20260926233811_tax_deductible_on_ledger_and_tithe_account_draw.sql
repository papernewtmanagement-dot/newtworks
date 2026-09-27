-- Peter 2026-09-26: mark each gift deductible or not on the ledger row itself (no new table).
-- The rule that classifies a row carries the yes/no; one trigger copies it onto the row.
ALTER TABLE public.ledger ADD COLUMN IF NOT EXISTS tax_deductible boolean;
COMMENT ON COLUMN public.ledger.tax_deductible IS
  'True when this gift counts toward the personal itemized charitable deduction. Copied from the classifying rule (gl_classification_rules.tax_deductible). Blank or false = not deductible (e.g. gifts to individuals).';
ALTER TABLE public.ledger_backfill_20260926 ADD COLUMN IF NOT EXISTS tax_deductible boolean;
ALTER TABLE public.gl_classification_rules ADD COLUMN IF NOT EXISTS tax_deductible boolean;
COMMENT ON COLUMN public.gl_classification_rules.tax_deductible IS
  'For giving rules: true when payments matched by this rule are tax deductible (qualified charity), false when not (gifts to people).';

CREATE OR REPLACE FUNCTION public.ledger_copy_tax_deductible() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public' AS $$
BEGIN
  IF NEW.rule_id_used IS NOT NULL THEN
    SELECT r.tax_deductible INTO NEW.tax_deductible FROM gl_classification_rules r WHERE r.id = NEW.rule_id_used;
  ELSIF TG_OP = 'UPDATE' AND OLD.rule_id_used IS NOT NULL THEN
    NEW.tax_deductible := NULL;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS ledger_copy_tax_deductible ON public.ledger;
CREATE TRIGGER ledger_copy_tax_deductible BEFORE INSERT OR UPDATE OF rule_id_used ON public.ledger
  FOR EACH ROW EXECUTE FUNCTION public.ledger_copy_tax_deductible();

-- Anything booked to Tithe & Charitable comes out of the tithe pool, whatever card or bank paid it.
ALTER TABLE public.tithe_draw_rules ADD COLUMN IF NOT EXISTS match_account_code text;
ALTER TABLE public.tithe_draw_rules DROP CONSTRAINT IF EXISTS tithe_draw_rules_check;
ALTER TABLE public.tithe_draw_rules ADD CONSTRAINT tithe_draw_rules_check
  CHECK (match_payee_regex IS NOT NULL OR match_source_account IS NOT NULL OR match_account_code IS NOT NULL);
DO $$
DECLARE d text; anchor text := E'   AND (d.match_source_account IS NULL OR d.match_source_account = ledger_paid_from_code(l.id))\n  WHERE l.agency_id = p_agency_id\n    AND coa.account_type = ''expense''';
BEGIN
  SELECT pg_get_functiondef('public.tithe_pool_reconcile'::regproc) INTO d;
  IF position('match_account_code' IN d) > 0 THEN RETURN; END IF;
  IF position(anchor IN d) = 0 THEN RAISE EXCEPTION 'tithe_pool_reconcile body not as expected'; END IF;
  d := replace(d, anchor, E'   AND (d.match_source_account IS NULL OR d.match_source_account = ledger_paid_from_code(l.id))\n   AND (d.match_account_code IS NULL OR d.match_account_code = coa.account_code)\n  WHERE l.agency_id = p_agency_id\n    AND coa.account_type = ''expense''');
  EXECUTE d;
END $$;

INSERT INTO tithe_draw_rules (agency_id, rule_name, priority, is_active, is_scheduled, effective_from, match_payee_regex, match_source_account, match_account_code, notes)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Any gift booked to Tithe & Charitable', 50, true, false, '2026-01-01', NULL, NULL, '9700',
       'Peter 2026-09-26: every gift in Tithe & Charitable comes out of the pool, whatever paid it (one-off gifts from checking, GoFundMe, Venmo).'
WHERE NOT EXISTS (SELECT 1 FROM tithe_draw_rules WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND match_account_code='9700');

UPDATE gl_classification_rules SET tax_deductible = true, updated_at = now()
 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
   AND id IN ('6adb7020-cbb7-47b7-9174-9179f924aefe','dff5f975-fa59-43db-9521-3c6ad3cd9d71','92e65c4f-9d32-4397-9248-f2ad6d90bdce');
INSERT INTO gl_classification_rules (agency_id, rule_name, match_priority, match_payee_regex, match_source_account, match_direction,
   debit_account_code, credit_account_code, target_business_entity_id, rule_scope, source, is_active, confidence, tax_deductible)
VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'GoFundMe (gifts to people) -> Personal Tithe & Charitable, not deductible', 50, '(?i)GO\s*FU?ND\s*ME|GOFNDME', NULL, 'both', '9700', '9700', 'b3333333-3333-3333-3333-333333333333', 'both', 'peter_2026-09-26', true, 'high', false),
 ('126794dd-25ff-47d2-a436-724499733365', 'Volunteer Firefighter -> Personal Tithe & Charitable, deductible', 50, '(?i)VOLUNTEER\s*FIRE', NULL, 'both', '9700', '9700', 'b3333333-3333-3333-3333-333333333333', 'both', 'peter_2026-09-26', true, 'high', true);
