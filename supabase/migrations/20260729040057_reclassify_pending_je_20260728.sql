-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 04:00:57 UTC (ledger name: reclassify_pending_je_20260728) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729040057.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Reclassifier for pending_review JEs sitting in Suspense.
-- Re-applies gl_classification_rules against the JE description, moves the
-- Suspense journal_line to the rule's target account, marks the JE classified.
-- Supports filter by source (card/bank) account_code, filter by single je_id, and dry-run preview.

CREATE OR REPLACE FUNCTION public.reclassify_pending_je(
  p_agency_id uuid,
  p_source_account_code text DEFAULT NULL,
  p_je_id uuid DEFAULT NULL,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_susp_account_id uuid;
  v_je RECORD;
  v_susp_line RECORD;
  v_other_line RECORD;
  v_source_account_code text;
  v_amount numeric;
  v_direction text;
  v_rule_id uuid;
  v_target_code text;
  v_new_account_id uuid;
  v_je_description text;
  v_count_reclassified int := 0;
  v_count_still_pending int := 0;
  v_count_error int := 0;
  v_count_scanned int := 0;
  v_details jsonb := '[]'::jsonb;
BEGIN
  SELECT id INTO v_susp_account_id
    FROM public.chart_of_accounts
    WHERE agency_id = p_agency_id AND account_code = 'COA-SUSP'
    LIMIT 1;

  IF v_susp_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'suspense_account_not_found');
  END IF;

  FOR v_je IN
    SELECT je.id, je.entry_date, je.description, je.reference_number
    FROM public.journal_entries je
    WHERE je.agency_id = p_agency_id
      AND je.classification_status = 'pending_review'
      AND (p_je_id IS NULL OR je.id = p_je_id)
    ORDER BY je.entry_date, je.id
  LOOP
    v_count_scanned := v_count_scanned + 1;

    SELECT jl.id, jl.debit, jl.credit
    INTO v_susp_line
    FROM public.journal_lines jl
    WHERE jl.journal_entry_id = v_je.id
      AND jl.account_id = v_susp_account_id
    LIMIT 1;

    IF NOT FOUND THEN
      v_count_still_pending := v_count_still_pending + 1;
      CONTINUE;
    END IF;

    SELECT jl.account_id, coa.account_code
    INTO v_other_line
    FROM public.journal_lines jl
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE jl.journal_entry_id = v_je.id
      AND jl.account_id != v_susp_account_id
    LIMIT 1;

    IF NOT FOUND THEN
      v_count_still_pending := v_count_still_pending + 1;
      CONTINUE;
    END IF;

    IF p_source_account_code IS NOT NULL AND v_other_line.account_code != p_source_account_code THEN
      v_count_scanned := v_count_scanned - 1;
      CONTINUE;
    END IF;

    v_source_account_code := v_other_line.account_code;

    IF v_susp_line.debit > 0 THEN
      v_amount := v_susp_line.debit;
      v_direction := 'debit';
    ELSE
      v_amount := v_susp_line.credit;
      v_direction := 'credit';
    END IF;

    v_je_description := v_je.description;

    v_rule_id := NULL;
    v_target_code := NULL;

    SELECT r.id,
      CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END
    INTO v_rule_id, v_target_code
    FROM public.gl_classification_rules r
    WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
      AND (r.match_payee_regex IS NULL OR v_je_description ~* r.match_payee_regex)
      AND (r.match_memo_regex IS NULL OR v_je_description ~* r.match_memo_regex)
      AND (r.match_source_account IS NULL OR r.match_source_account = v_source_account_code)
      AND (r.match_amount_min IS NULL OR abs(v_amount) >= r.match_amount_min)
      AND (r.match_amount_max IS NULL OR abs(v_amount) <= r.match_amount_max)
      AND (r.match_direction IS NULL OR r.match_direction = v_direction OR r.match_direction = 'both')
    ORDER BY r.match_priority ASC NULLS LAST
    LIMIT 1;

    IF v_rule_id IS NULL OR v_target_code IS NULL OR v_target_code = '__SOURCE__' THEN
      v_count_still_pending := v_count_still_pending + 1;
      CONTINUE;
    END IF;

    SELECT id INTO v_new_account_id
      FROM public.chart_of_accounts
      WHERE agency_id = p_agency_id
        AND account_code = v_target_code
        AND is_active = TRUE
      LIMIT 1;

    IF v_new_account_id IS NULL THEN
      v_count_error := v_count_error + 1;
      v_details := v_details || jsonb_build_object(
        'je_id', v_je.id, 'error', 'target_account_not_found', 'target_code', v_target_code
      );
      CONTINUE;
    END IF;

    v_details := v_details || jsonb_build_object(
      'je_id', v_je.id,
      'date', v_je.entry_date,
      'description', LEFT(v_je_description, 80),
      'source_card', v_source_account_code,
      'amount', v_amount,
      'direction', v_direction,
      'rule_id', v_rule_id,
      'target_code', v_target_code
    );

    IF NOT p_dry_run THEN
      UPDATE public.journal_lines
      SET account_id = v_new_account_id
      WHERE id = v_susp_line.id;

      UPDATE public.journal_entries
      SET classification_status = 'classified',
          suspense_reason = NULL,
          rule_id_used = v_rule_id,
          classified_by = 'reclassify_pending_je',
          classified_at = NOW()
      WHERE id = v_je.id;

      UPDATE public.gl_classification_rules
      SET historical_uses = COALESCE(historical_uses, 0) + 1,
          last_used_at = NOW()
      WHERE id = v_rule_id;
    END IF;

    v_count_reclassified := v_count_reclassified + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', TRUE,
    'dry_run', p_dry_run,
    'source_account_code_filter', p_source_account_code,
    'scanned', v_count_scanned,
    'reclassified', v_count_reclassified,
    'still_pending', v_count_still_pending,
    'errors', v_count_error,
    'details', v_details
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reclassify_pending_je(uuid, text, uuid, boolean) TO authenticated;
