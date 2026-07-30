-- ==========================================================================
-- Ledger dedup follow-up (Items 1 + 3 of the reconciliation guard scope)
--
-- Item 1: sign-agnostic ledger dedup pass — parent thread found $493.01 AMEX
-- sign-flip dup slipped past bank_transactions.uq_bank_transactions_dedup.
-- credit_transactions had NO dedup at all.
--
-- Item 3: description-format drift dedup — AMEX Discretionary txns parsed
-- twice with slightly different descriptions. Existing exact-description
-- dedup misses these.
--
-- Solution: PERIODIC PASS, not hard unique constraint. Legitimate same-day
-- charge+refund pairs and same-day identical-amount charges are real events;
-- hard-blocking them would be wrong. Instead, scan and raise alerts for
-- human review whenever (agency, account, date, abs(amount)) fingerprint
-- matches multiple rows.
-- ==========================================================================

-- 1. Add dedup_fingerprint to credit_transactions (mirrors bank_transactions column)
ALTER TABLE public.credit_transactions
  ADD COLUMN IF NOT EXISTS dedup_fingerprint text;

COMMENT ON COLUMN public.credit_transactions.dedup_fingerprint IS
  'Text fingerprint for dedup detection. Format: {account_last4}|{date}|{amount}|{description}. Populated by parser paths. Mirrors bank_transactions.dedup_fingerprint. Signed amount preserved for exact-match uniqueness; sign-flip near-dups caught by the periodic v_ledger_dup_candidates view + raise_ledger_dup_candidate_alerts pass.';

-- Backfill existing rows
UPDATE public.credit_transactions ct
SET dedup_fingerprint = 
  COALESCE(ca.account_number_last4, 'unk')
  || '|' || ct.transaction_date::text
  || '|' || ct.amount::text
  || '|' || COALESCE(ct.description, '')
FROM public.credit_accounts ca
WHERE ct.credit_account_id = ca.id
  AND ct.dedup_fingerprint IS NULL
  AND ct.agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 2. Ledger dup candidate view
CREATE OR REPLACE VIEW public.v_ledger_dup_candidates AS
WITH bank_dups AS (
  SELECT 
    'bank_transactions'::text AS source_table,
    agency_id,
    bank_account_id AS account_id,
    transaction_date,
    ABS(amount) AS abs_amount,
    count(*)::int AS n,
    array_agg(id ORDER BY created_at) AS row_ids,
    array_agg(amount ORDER BY created_at) AS amounts,
    array_agg(description ORDER BY created_at) AS descriptions
  FROM public.bank_transactions
  WHERE superseded_by IS NULL
  GROUP BY agency_id, bank_account_id, transaction_date, ABS(amount)
  HAVING count(*) >= 2
),
credit_dups AS (
  SELECT 
    'credit_transactions'::text AS source_table,
    agency_id,
    credit_account_id AS account_id,
    transaction_date,
    ABS(amount) AS abs_amount,
    count(*)::int AS n,
    array_agg(id ORDER BY created_at) AS row_ids,
    array_agg(amount ORDER BY created_at) AS amounts,
    array_agg(description ORDER BY created_at) AS descriptions
  FROM public.credit_transactions
  GROUP BY agency_id, credit_account_id, transaction_date, ABS(amount)
  HAVING count(*) >= 2
)
SELECT * FROM bank_dups
UNION ALL
SELECT * FROM credit_dups;

COMMENT ON VIEW public.v_ledger_dup_candidates IS
  'Ledger duplicate candidates: rows sharing (agency, account, date, abs(amount)) with another row on the same key. Captures sign-flip dups (parser hallucination) AND description-drift dups (same event parsed with different noise levels) in one pass. Legitimate same-day charge+refund pairs also appear — human review distinguishes real from bug.';

-- 3. Pass function
CREATE OR REPLACE FUNCTION public.raise_ledger_dup_candidate_alerts(p_agency_id uuid)
RETURNS TABLE (candidates_found int, alerts_raised int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_candidates_found int := 0;
  v_alerts_raised int := 0;
  r record;
  v_module_ref text;
  v_existing_alert_id uuid;
  v_first_id text;
  v_desc_preview text;
  v_signs_differ boolean;
BEGIN
  FOR r IN
    SELECT * FROM public.v_ledger_dup_candidates
    WHERE agency_id = p_agency_id
  LOOP
    v_candidates_found := v_candidates_found + 1;
    v_first_id := r.row_ids[1]::text;
    v_module_ref := 'ledger_dup_candidate:' || r.source_table || ':' || v_first_id;
    
    SELECT id INTO v_existing_alert_id
    FROM public.alerts
    WHERE agency_id = p_agency_id AND module_reference = v_module_ref
    LIMIT 1;
    IF v_existing_alert_id IS NOT NULL THEN
      CONTINUE;
    END IF;
    
    v_signs_differ := EXISTS (SELECT 1 FROM unnest(r.amounts) a WHERE a > 0)
                  AND EXISTS (SELECT 1 FROM unnest(r.amounts) a WHERE a < 0);
    v_desc_preview := left(COALESCE(r.descriptions[1], ''), 60);
    
    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, related_id, is_read, is_resolved, created_at
    )
    VALUES (
      p_agency_id,
      CASE WHEN v_signs_differ THEN 'ledger_dup_candidate_signflip' ELSE 'ledger_dup_candidate' END,
      CASE WHEN v_signs_differ THEN 'high' ELSE 'medium' END,
      format('Ledger dup candidate: %s x%s on %s ($%s)',
             v_desc_preview, r.n, r.transaction_date, r.abs_amount),
      format(
        E'Table: %s\nDate: %s\nAbs amount: $%s\nRow count: %s\nAmounts: %s\nDescriptions:\n  - %s\n\nRow IDs: %s\n\n%s',
        r.source_table, r.transaction_date, r.abs_amount, r.n,
        r.amounts::text,
        array_to_string(r.descriptions, E'\n  - '),
        r.row_ids::text,
        CASE WHEN v_signs_differ
             THEN 'SIGN-FLIP: rows on same date+account+abs(amount) with opposite signs. Likely parser hallucination unless legitimate same-day charge+refund pair.'
             ELSE 'Same date+account+abs(amount) captured multiple times. Likely exact repeat from re-parsed statement or overlapping ingestion, or description-format drift on the same real event.'
        END
      ),
      v_module_ref,
      r.row_ids[1],
      false, false, now()
    );
    v_alerts_raised := v_alerts_raised + 1;
  END LOOP;
  
  RETURN QUERY SELECT v_candidates_found, v_alerts_raised;
END;
$function$;

COMMENT ON FUNCTION public.raise_ledger_dup_candidate_alerts(uuid) IS
  'Scans v_ledger_dup_candidates for the agency, emits one alert per unresolved dup group. Idempotent via module_reference dedup. Sign-flip candidates get alert_type=ledger_dup_candidate_signflip and severity=high; plain repeats are severity=medium.';

-- 4. Wrapper for automation_recipes dispatcher (signature: uuid, uuid -> jsonb)
CREATE OR REPLACE FUNCTION public.run_ledger_dup_pass(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_result record;
BEGIN
  SELECT * INTO v_result FROM public.raise_ledger_dup_candidate_alerts(p_agency_id);
  RETURN jsonb_build_object(
    'ok', true,
    'candidates_found', v_result.candidates_found,
    'alerts_raised', v_result.alerts_raised
  );
END;
$function$;

COMMENT ON FUNCTION public.run_ledger_dup_pass(uuid, uuid) IS
  'automation_recipes wrapper for raise_ledger_dup_candidate_alerts. Returns jsonb with candidates_found + alerts_raised.';

-- 5. Daily automation_recipe: run pass after GL writers
INSERT INTO public.automation_recipes 
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, timezone, internal_handler, is_active)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Ledger Dup Candidate Pass',
  'Daily scan across bank_transactions + credit_transactions for rows sharing (agency, account, date, abs(amount)). Emits alerts for candidates without existing alerts. Sign-flip pairs get severity=high (likely parser hallucination); plain repeats get severity=medium (likely re-ingestion or description drift). Idempotent — re-runs do not double-alert. Runs after GL writers so day-of ingests are included.',
  'cron',
  '0 12 * * *',
  'America/Chicago',
  'run_ledger_dup_pass',
  true
)
ON CONFLICT DO NOTHING;

-- 6. Backfill alerts for current candidates (one-time pass)
SELECT * FROM public.raise_ledger_dup_candidate_alerts('126794dd-25ff-47d2-a436-724499733365'::uuid);
