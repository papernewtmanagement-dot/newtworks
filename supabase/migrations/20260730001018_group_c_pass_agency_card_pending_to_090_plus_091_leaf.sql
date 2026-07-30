-- Pass 4 — Group C: personal-shaped spend on agency cards routes to agency-side leaf.
-- Peter's directive: 84 Discretionary lines + 6 Discretionary lines from other agency cards → COA-SUB-090.
-- 63 CURRENTLY-PENDING JEs on agency cards get their *Unclassified placeholder swapped to COA-SUB-090.
-- No insurance-shaped patterns in the current pending set (State Farm Insurance, Ameritas etc.
-- verified zero in pending on agency cards), so 091 is created as the future landing zone but
-- not swept into today.

-- 1. Create COA-SUB-091 Personal - Insurance (agency card). Peter's option (b) from handoff item 5.
--    Parent = 0006 PERSONAL (same as COA-SUB-090).
INSERT INTO public.chart_of_accounts
  (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype,
   parent_account_id, is_active, created_at)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'b2222222-2222-2222-2222-222222222222',
  'COA-SUB-091',
  'Personal - Insurance (agency card)',
  'expense',
  'task3_split_label',
  (SELECT id FROM public.chart_of_accounts
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND account_code = 'COA-SUB-090'
     AND is_active = true LIMIT 1),
  true,
  NOW()
WHERE NOT EXISTS (
  SELECT 1 FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-SUB-091'
);

UPDATE public.chart_of_accounts new_leaf
SET parent_account_id = (
  SELECT parent_account_id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-SUB-090' LIMIT 1
)
WHERE new_leaf.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND new_leaf.account_code = 'COA-SUB-091';

-- 2. Sweep the 63 pending JEs on agency cards → swap *Unclassified line to COA-SUB-090.
WITH target_je AS (
  SELECT DISTINCT je.id AS je_id
  FROM public.journal_entries je
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND je.classification_status = 'pending_review'
    AND EXISTS (
      SELECT 1 FROM public.journal_lines jl
      JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
      WHERE jl.journal_entry_id = je.id
        AND coa.account_code IN ('COA-010','COA-011','COA-012','COA-013','COA-014','COA-028','COA-036','2100','2110','2120')
    )
    AND EXISTS (
      SELECT 1 FROM public.journal_lines jl
      JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
      WHERE jl.journal_entry_id = je.id
        AND coa.account_name = '*Unclassified'
    )
),
target_line AS (
  SELECT jl.id AS line_id, tj.je_id
  FROM public.journal_lines jl
  JOIN target_je tj ON tj.je_id = jl.journal_entry_id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE coa.account_name = '*Unclassified'
),
target_coa AS (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-SUB-090' LIMIT 1
)
UPDATE public.journal_lines jl
SET account_id = (SELECT id FROM target_coa)
WHERE jl.id IN (SELECT line_id FROM target_line);

-- 3. Flip status on the swept JEs.
UPDATE public.journal_entries
SET classification_status = 'classified',
    classified_by = 'group_c_sweep_2026_07_29',
    classified_at = NOW()
WHERE id IN (
  SELECT DISTINCT je.id
  FROM public.journal_entries je
  JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND je.classification_status = 'pending_review'
    AND coa.account_code = 'COA-SUB-090'
    AND EXISTS (
      SELECT 1 FROM public.journal_lines jl2
      JOIN public.chart_of_accounts coa2 ON coa2.id = jl2.account_id
      WHERE jl2.journal_entry_id = je.id
        AND coa2.account_code IN ('COA-010','COA-011','COA-012','COA-013','COA-014','COA-028','COA-036','2100','2110','2120')
    )
);
