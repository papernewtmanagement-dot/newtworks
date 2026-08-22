-- Three categories of duplicate / fake JEs to hard-delete, and one trigger to harden.
--
-- Category A (42 JEs): claude_bank_reparse duplicates. A one-off re-parse pass on
--   2026-07-17 re-ingested bank/CC statement lines that cc_gl_writer / bank_gl_writer
--   had already posted. Every one confirmed vendor-matched to an existing original.
--
-- Category B (30 JEs = 15 VOIDED + 15 REVERSAL): payroll bookkeeping artifacts from
--   the 2026-07-18/19 legacy-key remap event. Net-zero on P&L (matched pairs) but
--   they inflate ledger noise and violate the "no fake transactions" bar.
--
-- Category C (12 JEs): pf4c_smvc_to_eriosto backfill entries duplicated by the
--   pair_eriosto_on_smvc_credit trigger, which fired on later pf4_personal_backfill
--   inserts whose parent JE description already contained "SMVC TRUCKING". Trigger
--   couldn't dedup because the guard required a non-NULL bank_transactions link
--   (pf4_personal_backfill JEs aren't linked to bank_transactions rows).
--
-- Trigger hardening: replace v_bt_id-in-description LIKE match with a direct
-- (account, date, amount) lookup. Robust to any source path, no bank_transactions
-- linkage assumption.

-- ============================================================
-- Category A — claude_bank_reparse duplicates
-- ============================================================
WITH pl AS (
  SELECT je.id AS je_id, je.entry_date, je.source, jl.debit, jl.credit,
         coa.account_type, coa.business_entity_id, jl.account_id
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND coa.account_type IN ('income','expense')
),
reparse AS (SELECT * FROM pl WHERE source = 'claude_bank_reparse'),
originals AS (SELECT * FROM pl WHERE source IN ('cc_gl_writer','bank_gl_writer')),
reparse_dupes AS (
  SELECT DISTINCT r.je_id
  FROM reparse r
  JOIN originals o
    ON r.entry_date = o.entry_date AND r.account_id = o.account_id
   AND r.debit = o.debit AND r.credit = o.credit
)
DELETE FROM public.journal_entries WHERE id IN (SELECT je_id FROM reparse_dupes);

-- ============================================================
-- Category B — payroll VOIDED + REVERSAL artifacts
-- ============================================================
DELETE FROM public.journal_entries
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND (
    description ILIKE '%[VOIDED%'
    OR source LIKE '%_reversal'
    OR description ILIKE 'REVERSAL of %'
  );

-- ============================================================
-- Category C — pf4c_smvc_to_eriosto entries duplicated by trigger
-- ============================================================
WITH pf4c AS (
  SELECT DISTINCT je.id AS je_id, je.entry_date, jl.account_id, jl.debit, jl.credit
  FROM public.journal_entries je
  JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND je.source = 'pf4c_smvc_to_eriosto'
),
trg AS (
  SELECT DISTINCT jl.account_id, je.entry_date, jl.debit, jl.credit
  FROM public.journal_entries je
  JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND je.source = 'trg_pair_eriosto_on_smvc'
),
pf4c_dupes AS (
  SELECT DISTINCT p.je_id
  FROM pf4c p
  JOIN trg t ON t.entry_date = p.entry_date AND t.account_id = p.account_id
            AND t.debit = p.debit AND t.credit = p.credit
)
DELETE FROM public.journal_entries WHERE id IN (SELECT je_id FROM pf4c_dupes);

-- ============================================================
-- Harden the trigger dedup guard
-- ============================================================
CREATE OR REPLACE FUNCTION public.pair_eriosto_on_smvc_credit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_je RECORD;
  v_amount NUMERIC;
  v_tanker_count NUMERIC;
  v_tanker_text TEXT;
  v_count_str TEXT;
  v_new_je_id UUID;
  v_bt_id UUID;
  v_eriosto_ar_acct CONSTANT UUID := 'b807eab3-951f-4ee7-9078-2d213d260802'::uuid;
  v_eriosto_rev_acct CONSTANT UUID := 'eecf8046-860a-4f4f-ad15-809069d4c0fb'::uuid;
BEGIN
  IF NEW.credit IS NULL OR NEW.credit <= 0 THEN RETURN NEW; END IF;

  SELECT * INTO v_je FROM public.journal_entries WHERE id = NEW.journal_entry_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  IF v_je.description !~* 'SMVC\s+TRUCKING' THEN RETURN NEW; END IF;

  -- Skip if this credit line was posted by the pair trigger itself.
  IF v_je.source = 'trg_pair_eriosto_on_smvc' THEN RETURN NEW; END IF;

  SELECT id INTO v_bt_id FROM public.bank_transactions WHERE journal_entry_id = v_je.id LIMIT 1;

  -- Dedup guard (hardened 2026-07-31): match by (account, date, amount) across
  -- ALL sources. Prior guard relied on v_bt_id-in-description LIKE, which
  -- silently short-circuited when v_bt_id was NULL (e.g. pf4_personal_backfill
  -- JEs that aren't linked to bank_transactions) and let dupes through.
  IF EXISTS (
    SELECT 1
    FROM public.journal_entries e
    JOIN public.journal_lines jl ON jl.journal_entry_id = e.id
    WHERE e.agency_id = v_je.agency_id
      AND e.entry_date = v_je.entry_date
      AND jl.account_id = v_eriosto_ar_acct
      AND jl.debit = NEW.credit
      AND e.id <> v_je.id
  ) THEN
    RETURN NEW;
  END IF;

  v_amount := NEW.credit;

  IF v_je.entry_date < DATE '2026-04-01' THEN
    v_tanker_count := v_amount / 310;
  ELSE
    v_tanker_count := v_amount / 300;
  END IF;

  v_count_str := rtrim(rtrim(v_tanker_count::text, '0'), '.');

  IF v_count_str = '1' THEN
    v_tanker_text := '1 tanker';
  ELSE
    v_tanker_text := v_count_str || ' tankers';
  END IF;

  UPDATE public.journal_entries
     SET description = 'Eriosto tanker rental — ' || v_tanker_text || ' (SMVC TRUCKING PAYROLL)'
   WHERE id = v_je.id
     AND description NOT LIKE 'Eriosto tanker rental —%';

  UPDATE public.bank_transactions
     SET description = 'Eriosto tanker rental — ' || v_tanker_text || ' (Electronic Deposit From SMVC TRUCKING PAYROLL)'
   WHERE journal_entry_id = v_je.id
     AND description NOT LIKE 'Eriosto tanker rental —%';

  INSERT INTO public.journal_entries
    (agency_id, entry_date, description, source, entry_type, created_by, classification_status)
  VALUES (
    v_je.agency_id, v_je.entry_date,
    'Eriosto tanker rental — ' || v_tanker_text ||
      COALESCE(' (cash held at Personal ' || v_bt_id::text || ')', ''),
    'trg_pair_eriosto_on_smvc', 'intercompany_revenue',
    'trg_pair_eriosto_on_smvc', 'classified'
  )
  RETURNING id INTO v_new_je_id;

  INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit)
  VALUES
    (v_new_je_id, v_je.agency_id, v_eriosto_ar_acct,  v_amount, 0.00),
    (v_new_je_id, v_je.agency_id, v_eriosto_rev_acct, 0.00,    v_amount);

  RETURN NEW;
END;
$function$;
