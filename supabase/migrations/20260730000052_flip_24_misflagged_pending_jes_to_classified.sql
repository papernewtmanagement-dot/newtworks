-- Pass 3: 24 pending_review JEs are actually routed cleanly to leaf COAs on both sides.
-- Writers (bank_gl_writer + cc_gl_writer) applied the correct classification rule but never
-- flipped classification_status from pending_review to classified. Silent bug on both writers.
--
-- Excluding 3 property tax JEs (Jan 27 JP Bexar x2 + Jan 27 COMAL COUNTY) — those are flagged
-- in handoff item 4 for re-route (currently on COA-PERSONAL-9900 Income Tax, likely wrong).

WITH pending AS (
  SELECT je.id
  FROM public.journal_entries je
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND je.classification_status = 'pending_review'
),
je_has_susp AS (
  SELECT DISTINCT je.id
  FROM public.journal_entries je
  JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE je.id IN (SELECT id FROM pending)
    AND (coa.account_name = '*Unclassified' OR coa.account_code LIKE '%SUSP%' OR coa.account_code LIKE '%UNCL%')
),
targets AS (
  SELECT id FROM pending
  WHERE id NOT IN (SELECT id FROM je_has_susp)
    -- exclude the 3 property tax re-route candidates
    AND id NOT IN (
      SELECT je.id
      FROM public.journal_entries je
      WHERE je.description ILIKE '%JP Bexar%'
         OR je.description ILIKE '%COMAL COUNTY%'
    )
)
UPDATE public.journal_entries
SET classification_status = 'classified',
    classified_by = 'sweep_misflagged_2026_07_29',
    classified_at = NOW()
WHERE id IN (SELECT id FROM targets);
