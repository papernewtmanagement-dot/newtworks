-- Pass 6: Google YouTube / Play → Personal Discretionary rule + sweep of the one pending JE.
-- Scoped to personal card sources only (COA-PERSONAL-CC-*) to avoid mis-routing agency-card
-- Google Play charges (those go through Group C to COA-SUB-090 instead).

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, confidence, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'Google YouTube / Play — Personal Discretionary',
   40, '(?i)GOOGLE\s*\*(YouTube|Google Play|GOOGLE PLAY|YTV|TV)', 'debit',
   'COA-PERSONAL-9800', '__SOURCE__', 'high', TRUE);

-- Sweep the one pending YouTube JE on Cap One Personal card 7435 → COA-PERSONAL-9800.
WITH target_je AS (
  SELECT DISTINCT je.id AS je_id
  FROM public.journal_entries je
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND je.classification_status = 'pending_review'
    AND je.description ILIKE '%GOOGLE%YouTube%'
    AND EXISTS (
      SELECT 1 FROM public.journal_lines jl JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
      WHERE jl.journal_entry_id = je.id AND coa.account_code LIKE 'COA-PERSONAL-CC-%'
    )
),
target_line AS (
  SELECT jl.id
  FROM public.journal_lines jl
  JOIN target_je tj ON tj.je_id = jl.journal_entry_id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE coa.account_name = '*Unclassified'
),
target_coa AS (
  SELECT id FROM public.chart_of_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND account_code = 'COA-PERSONAL-9800' LIMIT 1
),
upd_lines AS (
  UPDATE public.journal_lines
  SET account_id = (SELECT id FROM target_coa)
  WHERE id IN (SELECT id FROM target_line)
  RETURNING journal_entry_id
)
UPDATE public.journal_entries
SET classification_status = 'classified',
    classified_by = 'personal_youtube_sweep_2026_07_29',
    classified_at = NOW()
WHERE id IN (SELECT journal_entry_id FROM upd_lines);
