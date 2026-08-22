
-- Stop writing to journal_entries.business_entity_id and journal_lines.business_entity_id.
-- The entity is already carried by the accounts referenced (b807eab3... and eecf8046...
-- are both on Eriosto entity per chart_of_accounts). Also stop the guard-lookup that
-- keyed off je.business_entity_id — replace with a lookup keyed off the referenced
-- Eriosto account id in journal_lines.

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

  SELECT id INTO v_bt_id FROM public.bank_transactions WHERE journal_entry_id = v_je.id LIMIT 1;

  -- Dedup guard: has this bank transaction ALREADY paired to an Eriosto JE?
  -- Detect by looking for a JE that (a) references v_bt_id in its description AND
  -- (b) has a journal_line pointing at the Eriosto AR account.
  IF v_bt_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.journal_entries e
    JOIN public.journal_lines jl ON jl.journal_entry_id = e.id
    WHERE e.agency_id = v_je.agency_id
      AND jl.account_id = v_eriosto_ar_acct
      AND e.description LIKE '%' || v_bt_id::text || '%'
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

  -- INSERT paired Eriosto JE. Entity now flows through the accounts referenced,
  -- not through a journal_entries.business_entity_id column.
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

