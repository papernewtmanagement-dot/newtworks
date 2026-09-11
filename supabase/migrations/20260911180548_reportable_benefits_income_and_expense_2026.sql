-- Peter 2026-09-11: SF's medical, dental and life insurance contributions
-- (REPORTABLE BENEFITS on the comp statement) are part of his pay for tax
-- purposes AND tax deductible, so they book as income AND expense, netting to
-- zero. Found: only the income side existed, and only for June. Every other
-- 2026 month had neither side.
-- Expense side uses new category deduction_sf_benefit: medical + dental go to
-- 6115 S-Corp Medical - Owner (where his own AGENTS GROUP MEDICAL/DENTAL
-- deduction lines already go), life to 6110 Employee Benefits.

INSERT INTO public.comp_deduction_map (agency_id, comp_category, description_pattern, source_account_name, source_parent_account_name, source_account_code, source_business_entity_id, priority, is_active, notes)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.cat, v.pat, v.nm, '0001 ADMINISTRATION 6% > 5%> 5%', v.code, 'b2222222-2222-2222-2222-222222222222', v.pri, true,
       'SF benefit contribution, expense side of the income/expense gross-up (Peter 2026-09-11)'
FROM (VALUES ('deduction_sf_benefit', 'LIFE', 'Employee Benefits', '6110', 50),
             ('deduction_sf_benefit', NULL, 'S-Corp Medical — Owner', '6115', 100)) v(cat, pat, nm, code, pri)
WHERE NOT EXISTS (SELECT 1 FROM public.comp_deduction_map m WHERE m.agency_id='126794dd-25ff-47d2-a436-724499733365'
                  AND m.comp_category = v.cat AND m.description_pattern IS NOT DISTINCT FROM v.pat);

-- June's hand-entered income rows: attach to the statement they came from.
UPDATE public.comp_recap cr SET source_document_id = d.id
FROM public.documents d
WHERE d.file_name = '26_06_25 Compensation.pdf' AND d.groq_classification = 'comp_recap_daily'
  AND cr.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND cr.comp_category = 'reportable_benefit'
  AND cr.period_year = 2026 AND cr.period_month = 6 AND cr.source_document_id IS NULL;

-- Both sides for every month that had none; expense side for June.
WITH stmts(file_name, m, d, need_income) AS (VALUES
  ('26_01_27 Compensation.pdf', 1, 27, true), ('26_02_24 Compensation.pdf', 2, 24, true),
  ('26_03_26 Compensation.pdf', 3, 26, true), ('26_04_27 Compensation.pdf', 4, 27, true),
  ('26_05_26 Compensation.pdf', 5, 31, true), ('26_06_25 Compensation.pdf', 6, 30, false),
  ('26_07_28 Compensation.pdf', 7, 31, true), ('26_08_26 Compensation.pdf', 8, 31, true)),
lines(descr, amt) AS (VALUES ('MEDICAL INSURANCE CONTRIBUTION', 2118.94), ('GROUP DENTAL INSURANCE CONTRIBUTION', 66.38), ('LIFE INSURANCE CONTRIBUTION', 16.00)),
rows AS (
  SELECT s.*, l.descr, l.amt, 'reportable_benefit' AS cat, l.descr AS out_descr FROM stmts s CROSS JOIN lines l WHERE s.need_income
  UNION ALL
  SELECT s.*, l.descr, l.amt, 'deduction_sf_benefit', l.descr || ' (expense)' FROM stmts s CROSS JOIN lines l)
INSERT INTO public.comp_recap (agency_id, period_year, period_month, period_day, comp_type, comp_category, description, amount, is_aipp_eligible, is_scorecard_eligible, source_document_id, notes)
SELECT '126794dd-25ff-47d2-a436-724499733365', 2026, r.m, r.d, '2H', r.cat, r.out_descr, r.amt, false, false, doc.id,
  'SF benefit contribution from the statement''s REPORTABLE BENEFITS section. Income and expense per Peter 2026-09-11: pay for tax purposes, and deductible.'
FROM rows r JOIN public.documents doc ON doc.file_name = r.file_name AND doc.groq_classification = 'comp_recap_daily'
WHERE NOT EXISTS (SELECT 1 FROM public.comp_recap x WHERE x.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND x.period_year = 2026 AND x.period_month = r.m AND x.comp_category = r.cat AND x.description = r.out_descr);

-- Growth budget ceiling measures cash earnings; benefit contributions are not cash.
DO $$
DECLARE v_def text;
  v_old text := $q$AND NOT (comp_category = 'state_farm_bonuses' AND description ILIKE '%scorecard%');$q$;
  v_new text := $q$AND comp_category <> 'reportable_benefit'
      AND NOT (comp_category = 'state_farm_bonuses' AND description ILIKE '%scorecard%');$q$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname = 'get_growth_budget_ceiling' LIMIT 1;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'get_growth_budget_ceiling anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;