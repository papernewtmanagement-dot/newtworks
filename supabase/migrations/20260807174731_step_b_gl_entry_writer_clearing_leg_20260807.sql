-- 2026-08-07: gl_entry_writer used settings.gl_default_cash_account_code
-- (1012) as the offset for every comp_revenue/comp_deduction line, double-
-- counting cash that bank_gl_writer already posts as Dr 1012 / Cr 0005 for the
-- real State Farm deposit. Adds the gl_comp_clearing_account_code setting
-- (0005) and repoints the 361 existing gl_entry_writer lines that sit on 1012
-- over to 0005. The gl_entry_writer function body itself was already rewritten
-- via CREATE OR REPLACE in a prior migration this session
-- (gl_entry_writer_clearing_account_fix_20260807) -- restated here for the
-- ledger, since CREATE OR REPLACE is naturally idempotent.
-- Idempotent: safe to re-run.

INSERT INTO public.settings (agency_id, setting_key, setting_value, description, created_at, updated_at)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'gl_comp_clearing_account_code', '0005',
        'Offset account for gl_entry_writer comp_revenue/comp_deduction lines. Added 2026-08-07 to fix double-count against 1012; see gl_entry_writer comment block.',
        NOW(), NOW())
ON CONFLICT (agency_id, setting_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.comp_cash_leg_audit_20260807 AS
SELECT jl.*, je.entry_date AS je_entry_date, je.description AS je_description, je.source AS je_source
FROM public.journal_lines jl
JOIN public.journal_entries je ON je.id = jl.journal_entry_id
JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
WHERE jl.agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND je.source = 'gl_entry_writer'
  AND coa.account_code = '1012';

UPDATE public.journal_lines jl
SET account_id = 'e29a1e69-5558-4aaa-aa14-d5389ed2042a'  -- 0005 Suspense, PSS
WHERE jl.id IN (SELECT id FROM public.comp_cash_leg_audit_20260807);

UPDATE public.journal_entries je
SET memo = COALESCE(je.memo || E'\n\n', '') ||
  '2026-08-07: comp cash leg reclassified from 1012 US Bank Income to 0005 Suspense — split offset pending. bank_gl_writer already posts the real State Farm deposit as Dr 1012 / Cr 0005; this offset was double-counting the same cash in 1012. Reversible from comp_cash_leg_audit_20260807.'
WHERE je.id IN (SELECT DISTINCT journal_entry_id FROM public.comp_cash_leg_audit_20260807)
  AND (je.memo IS NULL OR je.memo NOT LIKE '%comp_cash_leg_audit_20260807%');
