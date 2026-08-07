-- 2026-08-07: bank_gl_writer was booking payroll cash leaving 1012 as expense
-- in 6010 Staff Wages. It is not expense -- payroll_gl_writer already expensed
-- these wages; the bank withdrawal only settles the liability. Reclass all 74
-- affected lines (PAYROLL SERVICE, ONLINE PAYROLL, MYCHILDSUPPORT, PAYCHEX TPS;
-- Jan 1 - Jul 31 2026) from 6010 to 2902 Due to PaperNewt LLC (PSS entity).
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS public.wages_reclass_audit_20260807 AS
SELECT jl.*, je.entry_date AS je_entry_date, je.description AS je_description, je.source AS je_source
FROM public.journal_lines jl
JOIN public.journal_entries je ON je.id = jl.journal_entry_id
WHERE jl.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND jl.account_id = '232126b3-89a2-4e3e-b25b-ba07b76990c0'  -- 6010 Staff Wages, PSS
  AND je.source = 'bank_gl_writer'
  AND je.entry_date BETWEEN '2026-01-01' AND '2026-07-31';

UPDATE public.journal_lines jl
SET account_id = '0bc8230b-d986-4ec1-8019-4f769105cac3'  -- 2902 Due to PaperNewt LLC, PSS
WHERE jl.id IN (SELECT id FROM public.wages_reclass_audit_20260807);

UPDATE public.journal_entries je
SET memo = COALESCE(je.memo || E'\n\n', '') ||
  '2026-08-07: payroll payment reclassified from 6010 Staff Wages to 2902 Due to PaperNewt LLC. Wages already expensed by payroll_gl_writer; the bank withdrawal settles the payroll obligation, not a second expense. Reversible from wages_reclass_audit_20260807.'
WHERE je.id IN (SELECT DISTINCT journal_entry_id FROM public.wages_reclass_audit_20260807)
  AND (je.memo IS NULL OR je.memo NOT LIKE '%wages_reclass_audit_20260807%');

UPDATE public.gl_classification_rules
SET debit_account_code = '2902', match_source_account = '1012'
WHERE id = '28c75e5d-be1e-472a-ba21-8163456c6727';

UPDATE public.gl_classification_rules
SET debit_account_code = '2902', match_source_account = '1012'
WHERE id = '5f6d3b92-09fc-4a71-a27a-ce47d4211a37';
