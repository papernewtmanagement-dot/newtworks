-- Item 5 Group C retroactive reclass: move 114 already-classified journal lines from Personal COAs
-- to agency-side leaves. Peter's directive: personal-shaped spend on agency cards belongs on the
-- agency-side P&L under 0006 PERSONAL, not on the personal-entity P&L.
--
-- 24 lines: COA-PERSONAL-9600 Personal Insurance + COA-036 → COA-SUB-091 Personal - Insurance (agency card)
-- 84 lines: COA-PERSONAL-9800 Discretionary + COA-036 → COA-SUB-090 Personal - Discretionary (agency card)
-- 6 lines:  COA-PERSONAL-9800 Discretionary + COA-010 → COA-SUB-090

WITH target_090 AS (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-SUB-090' LIMIT 1
),
target_091 AS (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-SUB-091' LIMIT 1
),
lines_to_090 AS (
  SELECT jl.id
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  JOIN public.chart_of_accounts personal_coa ON personal_coa.id = jl.account_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND personal_coa.account_code = 'COA-PERSONAL-9800'
    AND EXISTS (
      SELECT 1 FROM public.journal_lines jl2 JOIN public.chart_of_accounts coa2 ON coa2.id = jl2.account_id
      WHERE jl2.journal_entry_id = je.id
        AND coa2.account_code IN ('COA-010','COA-011','COA-012','COA-013','COA-014','COA-028','COA-036','2100','2110','2120')
    )
),
lines_to_091 AS (
  SELECT jl.id
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  JOIN public.chart_of_accounts personal_coa ON personal_coa.id = jl.account_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND personal_coa.account_code = 'COA-PERSONAL-9600'
    AND EXISTS (
      SELECT 1 FROM public.journal_lines jl2 JOIN public.chart_of_accounts coa2 ON coa2.id = jl2.account_id
      WHERE jl2.journal_entry_id = je.id
        AND coa2.account_code IN ('COA-010','COA-011','COA-012','COA-013','COA-014','COA-028','COA-036','2100','2110','2120')
    )
),
upd_090 AS (
  UPDATE public.journal_lines
  SET account_id = (SELECT id FROM target_090)
  WHERE id IN (SELECT id FROM lines_to_090)
  RETURNING 1
),
upd_091 AS (
  UPDATE public.journal_lines
  SET account_id = (SELECT id FROM target_091)
  WHERE id IN (SELECT id FROM lines_to_091)
  RETURNING 1
)
SELECT (SELECT COUNT(*) FROM upd_090) AS moved_to_090, (SELECT COUNT(*) FROM upd_091) AS moved_to_091;
