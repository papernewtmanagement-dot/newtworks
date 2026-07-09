-- =========================================================================
-- Namespace rename: {books_historical, bcc_sf} → {historical, active}
-- Also renames source_bucket values in v_trial_balance/v_income_statement to
-- match the unified vocabulary.
-- =========================================================================

BEGIN;

-- --------------------------------------------------------------------------
-- 1. Data updates (chart_of_accounts, journal_entries, settings)
-- --------------------------------------------------------------------------

-- 1a. chart_of_accounts.chart_namespace: bcc_sf → active, books_historical → historical
UPDATE public.chart_of_accounts
SET chart_namespace = CASE chart_namespace
  WHEN 'bcc_sf' THEN 'active'
  WHEN 'books_historical' THEN 'historical'
  ELSE chart_namespace
END
WHERE chart_namespace IN ('bcc_sf', 'books_historical');

-- 1b. journal_entries.source prefix: books_historical_import_YYYY → historical_import_YYYY
UPDATE public.journal_entries
SET source = REPLACE(source, 'books_historical_import', 'historical_import')
WHERE source LIKE 'books_historical_import%';

-- 1c. settings.gl_chart_namespace fallback value: books_historical → historical
UPDATE public.settings
SET setting_value = 'historical',
    updated_at = NOW()
WHERE setting_key = 'gl_chart_namespace'
  AND setting_value = 'books_historical';

-- 1d. chart_of_accounts.chart_namespace column default: 'bcc_sf' → 'active'
ALTER TABLE public.chart_of_accounts
  ALTER COLUMN chart_namespace SET DEFAULT 'active'::text;

-- --------------------------------------------------------------------------
-- 2. Rewrite views to reference new label values
-- --------------------------------------------------------------------------


-- 2.v_trial_balance
CREATE OR REPLACE VIEW public.v_trial_balance AS
 SELECT je.agency_id,
    coa.id AS account_id,
    coa.account_code,
    coa.account_name,
    coa.account_type,
    coa.parent_account_id,
    parent.account_name AS parent_account_name,
        CASE
            WHEN je.source ~~ 'historical_import%'::text THEN 'historical'::text
            WHEN je.source = ANY (ARRAY['gl_entry_writer'::text, 'payroll_gl_writer'::text, 'bank_gl_writer'::text, 'cc_gl_writer'::text, 'document_processor'::text, 'document_processor_drainer'::text, 'claude_adjustment'::text]) THEN 'active'::text
            ELSE 'other'::text
        END AS source_bucket,
    date_trunc('month'::text, je.entry_date::timestamp with time zone)::date AS month_start,
    je.entry_date,
    sum(jl.debit) AS total_debit,
    sum(jl.credit) AS total_credit,
        CASE
            WHEN coa.account_type = 'income'::text AND je.source ~~ 'historical_import%'::text THEN sum(jl.debit) - sum(jl.credit)
            WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text]) THEN sum(jl.debit) - sum(jl.credit)
            ELSE sum(jl.credit) - sum(jl.debit)
        END AS net_balance,
    count(DISTINCT je.id) AS entry_count
   FROM journal_entries je
     JOIN journal_lines jl ON jl.journal_entry_id = je.id
     JOIN chart_of_accounts coa ON coa.id = jl.account_id
     LEFT JOIN chart_of_accounts parent ON parent.id = coa.parent_account_id
  GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name, coa.account_type, coa.parent_account_id, parent.account_name, je.source, (date_trunc('month'::text, je.entry_date::timestamp with time zone)), je.entry_date;;


-- 2.v_income_statement
CREATE OR REPLACE VIEW public.v_income_statement AS
 SELECT je.agency_id,
    EXTRACT(year FROM je.entry_date)::integer AS period_year,
    EXTRACT(month FROM je.entry_date)::integer AS period_month,
    EXTRACT(year FROM je.entry_date)::integer AS year,
    EXTRACT(month FROM je.entry_date)::integer AS month,
    to_char(je.entry_date::timestamp with time zone, 'YYYY-MM'::text) AS period,
    date_trunc('month'::text, je.entry_date::timestamp with time zone)::date AS period_date,
    coa.id AS account_id,
    coa.account_code,
    coa.account_name,
    coa.account_type,
    coa.account_subtype,
    sum(jl.debit) AS total_debit,
    sum(jl.credit) AS total_credit,
        CASE
            WHEN coa.account_type = 'income'::text AND je.source ~~ 'historical_import%'::text THEN sum(jl.debit) - sum(jl.credit)
            WHEN coa.account_type = 'income'::text THEN sum(jl.credit) - sum(jl.debit)
            WHEN coa.account_type = 'expense'::text THEN sum(jl.debit) - sum(jl.credit)
            ELSE 0::numeric
        END AS amount
   FROM journal_lines jl
     JOIN journal_entries je ON je.id = jl.journal_entry_id
     JOIN chart_of_accounts coa ON coa.id = jl.account_id
  WHERE coa.account_type = ANY (ARRAY['income'::text, 'expense'::text])
  GROUP BY je.agency_id, je.entry_date, je.source, coa.id, coa.account_code, coa.account_name, coa.account_type, coa.account_subtype;;


-- 2.v_growth_budget_licensing_ytd
CREATE OR REPLACE VIEW public.v_growth_budget_licensing_ytd AS
 SELECT jl.agency_id,
    a.account_code,
    a.account_name,
    date_trunc('year'::text, COALESCE(je.entry_date::timestamp with time zone, jl.created_at))::date AS year_start,
    round(sum(COALESCE(jl.debit, 0::numeric) - COALESCE(jl.credit, 0::numeric)), 2) AS licensing_ytd_dollars,
    count(*) AS entry_count,
    jsonb_agg(jsonb_build_object('journal_entry_id', jl.journal_entry_id, 'entry_date', je.entry_date, 'debit', jl.debit, 'credit', jl.credit, 'description', jl.description) ORDER BY je.entry_date DESC) AS entries
   FROM journal_lines jl
     JOIN chart_of_accounts a ON a.id = jl.account_id
     LEFT JOIN journal_entries je ON je.id = jl.journal_entry_id
  WHERE a.account_code = '6715'::text AND a.chart_namespace = 'active'::text AND date_trunc('year'::text, COALESCE(je.entry_date::timestamp with time zone, jl.created_at)) = date_trunc('year'::text, CURRENT_DATE::timestamp with time zone)
  GROUP BY jl.agency_id, a.account_code, a.account_name, (date_trunc('year'::text, COALESCE(je.entry_date::timestamp with time zone, jl.created_at)));;


-- 2. Variance view: rename + rewrite (columns changed, cannot CREATE OR REPLACE)
DROP VIEW IF EXISTS public.v_variance_books_historical_vs_newtworks;

CREATE VIEW public.v_variance_historical_vs_active AS
 WITH historical_data AS (
         SELECT v_trial_balance.agency_id,
            v_trial_balance.account_id,
            v_trial_balance.account_code,
            v_trial_balance.account_name,
            v_trial_balance.account_type,
            v_trial_balance.parent_account_name,
            v_trial_balance.month_start,
            sum(v_trial_balance.net_balance) AS historical_balance,
            sum(v_trial_balance.total_debit) AS historical_debit,
            sum(v_trial_balance.total_credit) AS historical_credit
           FROM v_trial_balance
          WHERE v_trial_balance.source_bucket = 'historical'::text
          GROUP BY v_trial_balance.agency_id, v_trial_balance.account_id, v_trial_balance.account_code, v_trial_balance.account_name, v_trial_balance.account_type, v_trial_balance.parent_account_name, v_trial_balance.month_start
        ), active_data AS (
         SELECT v_trial_balance.agency_id,
            v_trial_balance.account_id,
            v_trial_balance.account_code,
            v_trial_balance.account_name,
            v_trial_balance.account_type,
            v_trial_balance.parent_account_name,
            v_trial_balance.month_start,
            sum(v_trial_balance.net_balance) AS active_balance,
            sum(v_trial_balance.total_debit) AS active_debit,
            sum(v_trial_balance.total_credit) AS active_credit
           FROM v_trial_balance
          WHERE v_trial_balance.source_bucket = 'active'::text
          GROUP BY v_trial_balance.agency_id, v_trial_balance.account_id, v_trial_balance.account_code, v_trial_balance.account_name, v_trial_balance.account_type, v_trial_balance.parent_account_name, v_trial_balance.month_start
        )
 SELECT COALESCE(h.agency_id, b.agency_id) AS agency_id,
    COALESCE(h.account_id, b.account_id) AS account_id,
    COALESCE(h.account_code, b.account_code) AS account_code,
    COALESCE(h.account_name, b.account_name) AS account_name,
    COALESCE(h.account_type, b.account_type) AS account_type,
    COALESCE(h.parent_account_name, b.parent_account_name) AS parent_account_name,
    COALESCE(h.month_start, b.month_start) AS month_start,
    to_char(COALESCE(h.month_start, b.month_start)::timestamp with time zone, 'YYYY-MM'::text) AS month_label,
    COALESCE(h.historical_balance, 0::numeric) AS historical_balance,
    COALESCE(b.active_balance, 0::numeric) AS active_balance,
    COALESCE(b.active_balance, 0::numeric) - COALESCE(h.historical_balance, 0::numeric) AS variance,
        CASE
            WHEN COALESCE(h.historical_balance, 0::numeric) = 0::numeric AND COALESCE(b.active_balance, 0::numeric) = 0::numeric THEN 0::numeric
            WHEN COALESCE(h.historical_balance, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE round((COALESCE(b.active_balance, 0::numeric) - COALESCE(h.historical_balance, 0::numeric)) / abs(h.historical_balance) * 100::numeric, 1)
        END AS variance_pct
   FROM historical_data h
     FULL JOIN active_data b ON h.agency_id = b.agency_id AND h.account_id = b.account_id AND h.month_start = b.month_start;;


-- --------------------------------------------------------------------------
-- 3. Rewrite GL writer functions (books_historical default fallback → historical)
-- --------------------------------------------------------------------------

-- bank_gl_writer
CREATE OR REPLACE FUNCTION public.bank_gl_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cutover_date date;
  v_chart_namespace text;
  v_suspense_account_id uuid;
  
  v_txn_id uuid;
  v_bank_account_id uuid;
  v_txn_date date;
  v_description text;
  v_amount numeric;
  v_txn_type text;
  v_category text;
  v_raw_split_label text;
  v_reference_number text;
  v_source_document_id uuid;
  v_posted_at timestamptz;
  v_existing_je_id uuid;
  
  v_other_side_account_id uuid;
  v_rule_id uuid;
  v_classification_status text;
  v_suspense_reason text;
  
  v_je_id uuid;
  
  v_count_eligible int := 0;
  v_count_skipped_cutover int := 0;
  v_count_skipped_already_posted int := 0;
  v_count_skipped_no_bank int := 0;
  v_count_posted_classified int := 0;
  v_count_posted_suspense int := 0;
  v_count_errored int := 0;
  
  v_total_posted numeric := 0;
  v_errors jsonb := '[]'::jsonb;
  v_posted_runs jsonb := '[]'::jsonb;
BEGIN
  -- Load settings
  SELECT setting_value::date INTO v_cutover_date
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '2026-05-01'::date; END IF;
  
  SELECT setting_value INTO v_chart_namespace
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN v_chart_namespace := 'historical'; END IF;
  
  -- Resolve suspense account
  SELECT id INTO v_suspense_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND account_code = 'COA-SUSP'
    LIMIT 1;
  
  IF v_suspense_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'suspense_account_not_found',
      'searched_for', 'COA-SUSP', 'namespace', v_chart_namespace);
  END IF;
  
  -- Walk bank_transactions
  FOR v_txn_id, v_bank_account_id, v_txn_date, v_description, v_amount, v_txn_type,
      v_category, v_raw_split_label, v_reference_number, v_source_document_id,
      v_posted_at, v_existing_je_id IN
    SELECT id, bank_account_id, transaction_date, description, amount, transaction_type,
           category, raw_split_label, reference_number, source_document_id,
           posted_at, journal_entry_id
    FROM bank_transactions
    WHERE agency_id = p_agency_id
    ORDER BY transaction_date, id
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_other_side_account_id := NULL;
    v_rule_id := NULL;
    v_classification_status := NULL;
    v_suspense_reason := NULL;
    
    -- Cutover gate
    IF v_txn_date < v_cutover_date THEN
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      IF NOT p_dry_run AND v_posted_at IS NULL THEN
        UPDATE bank_transactions
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover; no JE posted per accounting_rules]'
        WHERE id = v_txn_id;
      END IF;
      CONTINUE;
    END IF;
    
    -- Already posted
    IF v_posted_at IS NOT NULL AND v_existing_je_id IS NOT NULL THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1;
      CONTINUE;
    END IF;
    
    -- Validate bank account
    IF v_bank_account_id IS NULL THEN
      v_count_skipped_no_bank := v_count_skipped_no_bank + 1;
      v_errors := v_errors || jsonb_build_object(
        'txn_id', v_txn_id, 'reason', 'no_bank_account_id',
        'description', LEFT(v_description, 100)
      );
      CONTINUE;
    END IF;
    
    -- Validate amount
    IF v_amount IS NULL OR v_amount = 0 THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object(
        'txn_id', v_txn_id, 'reason', 'zero_or_null_amount'
      );
      CONTINUE;
    END IF;
    
    -- ===== Resolution waterfall =====
    
    -- 1. Direct category text match (look for exact account_name)
    IF v_category IS NOT NULL AND length(trim(v_category)) > 0 THEN
      SELECT id INTO v_other_side_account_id
        FROM chart_of_accounts
        WHERE agency_id = p_agency_id
          AND chart_namespace = v_chart_namespace
          AND account_name = v_category
          AND is_active = TRUE
        LIMIT 1;
      
      IF v_other_side_account_id IS NOT NULL THEN
        v_classification_status := 'classified';
      END IF;
    END IF;
    
    -- 2. raw_split_label match (e.g. "5005 ADMINISTRATION 6% > 5%> 5%:Building Maintenance")
    -- Extract the part after the colon and match that against sub-accounts
    IF v_other_side_account_id IS NULL AND v_raw_split_label IS NOT NULL 
       AND v_raw_split_label LIKE '%:%' THEN
      DECLARE v_sub_name text := trim(split_part(v_raw_split_label, ':', 2));
      BEGIN
        SELECT id INTO v_other_side_account_id
          FROM chart_of_accounts
          WHERE agency_id = p_agency_id
            AND chart_namespace = v_chart_namespace
            AND account_name = v_sub_name
            AND is_active = TRUE
          LIMIT 1;
        IF v_other_side_account_id IS NOT NULL THEN
          v_classification_status := 'classified';
        END IF;
      END;
    END IF;
    
    -- 3. gl_classification_rules priority match
    IF v_other_side_account_id IS NULL THEN
      DECLARE
        v_match_direction text;
        v_target_code text;
      BEGIN
        v_match_direction := CASE WHEN v_amount > 0 THEN 'credit' ELSE 'debit' END;
        
        SELECT 
          r.id,
          CASE WHEN v_amount > 0 THEN r.credit_account_code ELSE r.debit_account_code END
        INTO v_rule_id, v_target_code
        FROM gl_classification_rules r
        WHERE r.agency_id = p_agency_id
          AND r.is_active = TRUE
          AND (r.match_payee_regex IS NULL OR v_description ~* r.match_payee_regex)
          AND (r.match_memo_regex IS NULL OR v_description ~* r.match_memo_regex)
          AND (r.match_amount_min IS NULL OR abs(v_amount) >= r.match_amount_min)
          AND (r.match_amount_max IS NULL OR abs(v_amount) <= r.match_amount_max)
          AND (r.match_direction IS NULL OR r.match_direction = v_match_direction)
        ORDER BY r.match_priority ASC NULLS LAST
        LIMIT 1;
        
        IF v_rule_id IS NOT NULL AND v_target_code IS NOT NULL AND v_target_code != '__SOURCE__' THEN
          SELECT id INTO v_other_side_account_id
            FROM chart_of_accounts
            WHERE agency_id = p_agency_id
              AND chart_namespace = v_chart_namespace
              AND account_code = v_target_code
              AND is_active = TRUE
            LIMIT 1;
          
          IF v_other_side_account_id IS NOT NULL THEN
            v_classification_status := 'classified';
            -- Update rule usage stats
            UPDATE gl_classification_rules
            SET historical_uses = COALESCE(historical_uses, 0) + 1,
                last_used_at = NOW()
            WHERE id = v_rule_id;
          END IF;
        END IF;
      END;
    END IF;
    
    -- 4. Fallback to suspense
    IF v_other_side_account_id IS NULL THEN
      v_other_side_account_id := v_suspense_account_id;
      v_classification_status := 'pending_review';
      v_suspense_reason := CASE 
        WHEN v_category IS NULL OR length(trim(v_category)) = 0 THEN 'no_category_provided'
        ELSE 'category_unresolved: ' || left(v_category, 80)
      END;
    END IF;
    
    -- ===== Post the JE (or report it if dry_run) =====
    DECLARE
      v_dr_account_id uuid;
      v_cr_account_id uuid;
      v_abs_amount numeric := abs(v_amount);
      v_je_description text;
    BEGIN
      -- Direction: positive amount = inflow (DR bank, CR other side)
      --            negative amount = outflow (DR other side, CR bank)
      IF v_amount > 0 THEN
        v_dr_account_id := v_bank_account_id;
        v_cr_account_id := v_other_side_account_id;
      ELSE
        v_dr_account_id := v_other_side_account_id;
        v_cr_account_id := v_bank_account_id;
      END IF;
      
      v_je_description := COALESCE(v_description, 'Bank transaction') || 
                         CASE WHEN v_reference_number IS NOT NULL 
                              THEN ' [ref: ' || v_reference_number || ']'
                              ELSE '' END;
      
      IF p_dry_run THEN
        v_posted_runs := v_posted_runs || jsonb_build_object(
          'txn_id', v_txn_id,
          'date', v_txn_date,
          'amount', v_amount,
          'description', left(v_description, 80),
          'dr_account', v_dr_account_id,
          'cr_account', v_cr_account_id,
          'classification_status', v_classification_status,
          'rule_id', v_rule_id,
          'suspense_reason', v_suspense_reason
        );
        IF v_classification_status = 'classified' THEN
          v_count_posted_classified := v_count_posted_classified + 1;
        ELSE
          v_count_posted_suspense := v_count_posted_suspense + 1;
        END IF;
        v_total_posted := v_total_posted + v_abs_amount;
        CONTINUE;
      END IF;
      
      -- Insert JE
      INSERT INTO journal_entries (
        agency_id, entry_date, description, source, reference_number,
        classification_status, suspense_reason, rule_id_used, classified_by, classified_at,
        created_at
      ) VALUES (
        p_agency_id, v_txn_date, v_je_description,
        'bank_gl_writer', COALESCE(v_reference_number, 'BANKTXN-' || v_txn_id::text),
        v_classification_status, v_suspense_reason, v_rule_id,
        CASE WHEN v_classification_status = 'classified' AND v_rule_id IS NOT NULL THEN 'rule:' || v_rule_id::text
             WHEN v_classification_status = 'classified' THEN 'category_match'
             ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        NOW()
      ) RETURNING id INTO v_je_id;
      
      -- DR line
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_dr_account_id, v_abs_amount, 0, left(v_je_description, 200));
      
      -- CR line
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_cr_account_id, 0, v_abs_amount, left(v_je_description, 200));
      
      -- Mark txn posted
      UPDATE bank_transactions
      SET journal_entry_id = v_je_id,
          posted_at = NOW(),
          notes = COALESCE(notes, '') || ' [posted by bank_gl_writer ' || NOW()::text || 
                  CASE WHEN v_classification_status = 'pending_review' 
                       THEN '; suspense: ' || COALESCE(v_suspense_reason, 'unknown') 
                       ELSE '' END || ']'
      WHERE id = v_txn_id;
      
      IF v_classification_status = 'classified' THEN
        v_count_posted_classified := v_count_posted_classified + 1;
      ELSE
        v_count_posted_suspense := v_count_posted_suspense + 1;
      END IF;
      v_total_posted := v_total_posted + v_abs_amount;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'ok', TRUE,
    'dry_run', p_dry_run,
    'cutover_date', v_cutover_date,
    'eligible', v_count_eligible,
    'skipped_pre_cutover', v_count_skipped_cutover,
    'skipped_already_posted', v_count_skipped_already_posted,
    'skipped_no_bank_account', v_count_skipped_no_bank,
    'posted_classified', v_count_posted_classified,
    'posted_suspense', v_count_posted_suspense,
    'errors', v_count_errored,
    'total_amount_posted', v_total_posted,
    'posted_runs', v_posted_runs,
    'error_details', v_errors
  );
END;
$function$
;

-- cc_gl_writer
CREATE OR REPLACE FUNCTION public.cc_gl_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cutover_date date;
  v_chart_namespace text;
  v_suspense_account_id uuid;
  
  v_txn_id uuid;
  v_credit_account_id uuid;          -- FK to credit_accounts.id
  v_card_chart_account_id uuid;       -- resolved via JOIN
  v_card_name text;
  v_txn_date date;
  v_description text;
  v_amount numeric;
  v_txn_type text;
  v_category text;
  v_posted_at timestamptz;
  v_existing_je_id uuid;
  
  v_other_side_account_id uuid;
  v_rule_id uuid;
  v_classification_status text;
  v_suspense_reason text;
  
  v_je_id uuid;
  
  v_count_eligible int := 0;
  v_count_skipped_cutover int := 0;
  v_count_skipped_already_posted int := 0;
  v_count_skipped_no_card int := 0;
  v_count_skipped_unlinked_card int := 0;
  v_count_posted_classified int := 0;
  v_count_posted_suspense int := 0;
  v_count_errored int := 0;
  
  v_total_posted numeric := 0;
  v_errors jsonb := '[]'::jsonb;
  v_posted_runs jsonb := '[]'::jsonb;
BEGIN
  SELECT setting_value::date INTO v_cutover_date
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '2026-05-01'::date; END IF;
  
  SELECT setting_value INTO v_chart_namespace
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN v_chart_namespace := 'historical'; END IF;
  
  SELECT id INTO v_suspense_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace AND account_code = 'COA-SUSP'
    LIMIT 1;
  
  IF v_suspense_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'suspense_account_not_found');
  END IF;
  
  -- JOIN credit_transactions ↔ credit_accounts to resolve chart_account_id
  FOR v_txn_id, v_credit_account_id, v_card_chart_account_id, v_card_name,
      v_txn_date, v_description, v_amount, v_txn_type, v_category,
      v_posted_at, v_existing_je_id IN
    SELECT ct.id, ct.credit_account_id, ca.chart_account_id, ca.account_name,
           ct.transaction_date, ct.description, ct.amount, ct.transaction_type, ct.category,
           ct.posted_at, ct.journal_entry_id
    FROM credit_transactions ct
    LEFT JOIN credit_accounts ca ON ca.id = ct.credit_account_id
    WHERE ct.agency_id = p_agency_id
    ORDER BY ct.transaction_date, ct.id
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_other_side_account_id := NULL;
    v_rule_id := NULL;
    v_classification_status := NULL;
    v_suspense_reason := NULL;
    
    -- Cutover gate
    IF v_txn_date < v_cutover_date THEN
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      IF NOT p_dry_run AND v_posted_at IS NULL THEN
        UPDATE credit_transactions
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover; no JE posted per accounting_rules]'
        WHERE id = v_txn_id;
      END IF;
      CONTINUE;
    END IF;
    
    -- Already posted
    IF v_posted_at IS NOT NULL AND v_existing_je_id IS NOT NULL THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1;
      CONTINUE;
    END IF;
    
    -- Card account missing entirely
    IF v_credit_account_id IS NULL THEN
      v_count_skipped_no_card := v_count_skipped_no_card + 1;
      v_errors := v_errors || jsonb_build_object(
        'txn_id', v_txn_id, 'reason', 'no_credit_account_id', 'description', LEFT(v_description, 100)
      );
      CONTINUE;
    END IF;
    
    -- Card exists but no chart link
    IF v_card_chart_account_id IS NULL THEN
      v_count_skipped_unlinked_card := v_count_skipped_unlinked_card + 1;
      v_errors := v_errors || jsonb_build_object(
        'txn_id', v_txn_id, 'reason', 'credit_account_not_linked_to_chart',
        'card_name', v_card_name, 'credit_account_id', v_credit_account_id
      );
      CONTINUE;
    END IF;
    
    IF v_amount IS NULL OR v_amount = 0 THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object('txn_id', v_txn_id, 'reason', 'zero_or_null_amount');
      CONTINUE;
    END IF;
    
    -- ===== Resolution waterfall =====
    
    -- 1. Direct category match
    IF v_category IS NOT NULL AND length(trim(v_category)) > 0 THEN
      SELECT id INTO v_other_side_account_id
        FROM chart_of_accounts
        WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
          AND account_name = v_category AND is_active = TRUE
        LIMIT 1;
      IF v_other_side_account_id IS NOT NULL THEN
        v_classification_status := 'classified';
      END IF;
    END IF;
    
    -- 2. gl_classification_rules
    IF v_other_side_account_id IS NULL THEN
      DECLARE
        v_match_direction text;
        v_target_code text;
      BEGIN
        v_match_direction := CASE WHEN v_amount > 0 THEN 'credit' ELSE 'debit' END;
        
        SELECT r.id,
          CASE WHEN v_amount > 0 THEN r.credit_account_code ELSE r.debit_account_code END
        INTO v_rule_id, v_target_code
        FROM gl_classification_rules r
        WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
          AND (r.match_payee_regex IS NULL OR v_description ~* r.match_payee_regex)
          AND (r.match_memo_regex IS NULL OR v_description ~* r.match_memo_regex)
          AND (r.match_amount_min IS NULL OR abs(v_amount) >= r.match_amount_min)
          AND (r.match_amount_max IS NULL OR abs(v_amount) <= r.match_amount_max)
          AND (r.match_direction IS NULL OR r.match_direction = v_match_direction)
        ORDER BY r.match_priority ASC NULLS LAST
        LIMIT 1;
        
        IF v_rule_id IS NOT NULL AND v_target_code IS NOT NULL AND v_target_code != '__SOURCE__' THEN
          SELECT id INTO v_other_side_account_id
            FROM chart_of_accounts
            WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
              AND account_code = v_target_code AND is_active = TRUE
            LIMIT 1;
          IF v_other_side_account_id IS NOT NULL THEN
            v_classification_status := 'classified';
            UPDATE gl_classification_rules
            SET historical_uses = COALESCE(historical_uses, 0) + 1, last_used_at = NOW()
            WHERE id = v_rule_id;
          END IF;
        END IF;
      END;
    END IF;
    
    -- 3. Suspense fallback
    IF v_other_side_account_id IS NULL THEN
      v_other_side_account_id := v_suspense_account_id;
      v_classification_status := 'pending_review';
      v_suspense_reason := CASE 
        WHEN v_category IS NULL OR length(trim(v_category)) = 0 THEN 'no_category_provided'
        ELSE 'category_unresolved: ' || left(v_category, 80)
      END;
    END IF;
    
    -- ===== Post the JE =====
    DECLARE
      v_dr_account_id uuid;
      v_cr_account_id uuid;
      v_abs_amount numeric := abs(v_amount);
      v_je_description text;
    BEGIN
      -- Charge (negative amount): DR other-side, CR card
      -- Payment (positive amount): DR card, CR other-side
      IF v_amount < 0 THEN
        v_dr_account_id := v_other_side_account_id;
        v_cr_account_id := v_card_chart_account_id;
      ELSE
        v_dr_account_id := v_card_chart_account_id;
        v_cr_account_id := v_other_side_account_id;
      END IF;
      
      v_je_description := COALESCE(v_description, 'Credit card transaction') || ' [' || v_card_name || ']';
      
      IF p_dry_run THEN
        v_posted_runs := v_posted_runs || jsonb_build_object(
          'txn_id', v_txn_id, 'date', v_txn_date, 'amount', v_amount, 'card', v_card_name,
          'description', left(v_description, 80),
          'dr_account', v_dr_account_id, 'cr_account', v_cr_account_id,
          'classification_status', v_classification_status,
          'rule_id', v_rule_id, 'suspense_reason', v_suspense_reason
        );
        IF v_classification_status = 'classified' THEN
          v_count_posted_classified := v_count_posted_classified + 1;
        ELSE
          v_count_posted_suspense := v_count_posted_suspense + 1;
        END IF;
        v_total_posted := v_total_posted + v_abs_amount;
        CONTINUE;
      END IF;
      
      INSERT INTO journal_entries (
        agency_id, entry_date, description, source, reference_number,
        classification_status, suspense_reason, rule_id_used, classified_by, classified_at, created_at
      ) VALUES (
        p_agency_id, v_txn_date, v_je_description,
        'cc_gl_writer', 'CCTXN-' || v_txn_id::text,
        v_classification_status, v_suspense_reason, v_rule_id,
        CASE WHEN v_classification_status = 'classified' AND v_rule_id IS NOT NULL THEN 'rule:' || v_rule_id::text
             WHEN v_classification_status = 'classified' THEN 'category_match'
             ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        NOW()
      ) RETURNING id INTO v_je_id;
      
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_dr_account_id, v_abs_amount, 0, left(v_je_description, 200));
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_cr_account_id, 0, v_abs_amount, left(v_je_description, 200));
      
      UPDATE credit_transactions
      SET journal_entry_id = v_je_id, posted_at = NOW(),
          notes = COALESCE(notes, '') || ' [posted by cc_gl_writer ' || NOW()::text || 
                  CASE WHEN v_classification_status = 'pending_review' 
                       THEN '; suspense: ' || COALESCE(v_suspense_reason, 'unknown') 
                       ELSE '' END || ']'
      WHERE id = v_txn_id;
      
      IF v_classification_status = 'classified' THEN
        v_count_posted_classified := v_count_posted_classified + 1;
      ELSE
        v_count_posted_suspense := v_count_posted_suspense + 1;
      END IF;
      v_total_posted := v_total_posted + v_abs_amount;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'ok', TRUE, 'dry_run', p_dry_run, 'cutover_date', v_cutover_date,
    'eligible', v_count_eligible,
    'skipped_pre_cutover', v_count_skipped_cutover,
    'skipped_already_posted', v_count_skipped_already_posted,
    'skipped_no_card_account', v_count_skipped_no_card,
    'skipped_unlinked_card', v_count_skipped_unlinked_card,
    'posted_classified', v_count_posted_classified,
    'posted_suspense', v_count_posted_suspense,
    'errors', v_count_errored,
    'total_amount_posted', v_total_posted,
    'posted_runs', v_posted_runs,
    'error_details', v_errors
  );
END;
$function$
;

-- gl_entry_writer
CREATE OR REPLACE FUNCTION public.gl_entry_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cutover_date date;
  v_chart_namespace text;
  v_cash_acct_name text;
  v_sf_parent_name text;
  v_cash_acct_id uuid;
  v_sf_parent_id uuid;
  v_suspense_id uuid;
  v_id uuid;
  v_period_year int;
  v_period_month int;
  v_period_day int;
  v_comp_type text;
  v_comp_category text;
  v_amount numeric;
  v_description text;
  v_posted_at timestamptz;
  v_entry_date date;
  v_is_deduction boolean;
  v_target_account_id uuid;
  v_target_account_name text;
  v_classification_status text;
  v_suspense_reason text;
  v_je_id uuid;
  v_count_eligible int := 0;
  v_count_skipped_cutover int := 0;
  v_count_posted_rev int := 0;
  v_count_posted_ded int := 0;
  v_count_posted_susp int := 0;
  v_count_errored int := 0;
  v_total_revenue numeric := 0;
  v_total_deductions numeric := 0;
  v_posted_runs jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  SELECT setting_value::date INTO v_cutover_date FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '2026-05-01'::date; END IF;
  
  SELECT setting_value INTO v_chart_namespace FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN v_chart_namespace := 'historical'; END IF;
  
  SELECT setting_value INTO v_cash_acct_name FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_default_cash_account_name';
  IF v_cash_acct_name IS NULL THEN v_cash_acct_name := 'US Bank - Income'; END IF;
  
  SELECT setting_value INTO v_sf_parent_name FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_default_sf_revenue_account_name';
  IF v_sf_parent_name IS NULL THEN v_sf_parent_name := '4005 State Farm'; END IF;
  
  SELECT id INTO v_cash_acct_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
      AND account_name = v_cash_acct_name LIMIT 1;
  IF v_cash_acct_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'cash_account_not_found');
  END IF;
  
  SELECT id INTO v_sf_parent_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
      AND account_name = v_sf_parent_name AND parent_account_id IS NULL LIMIT 1;
  IF v_sf_parent_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'sf_parent_not_found');
  END IF;
  
  SELECT id INTO v_suspense_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
      AND account_code = 'COA-SUSP' LIMIT 1;
  IF v_suspense_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'suspense_account_not_found');
  END IF;
  
  FOR v_id, v_period_year, v_period_month, v_period_day, v_comp_type, v_comp_category,
      v_amount, v_description, v_posted_at IN
    SELECT id, period_year, period_month, period_day, comp_type, comp_category,
           amount, description, posted_at
    FROM comp_recap
    WHERE agency_id = p_agency_id AND posted_at IS NULL
      AND amount IS NOT NULL AND amount != 0
      AND period_year IS NOT NULL AND period_month IS NOT NULL
    ORDER BY period_year, period_month, period_day NULLS LAST, id
    LIMIT 1000
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_target_account_id := NULL;
    v_target_account_name := NULL;
    v_classification_status := NULL;
    v_suspense_reason := NULL;
    v_entry_date := MAKE_DATE(v_period_year, v_period_month, COALESCE(v_period_day, 1));
    
    IF v_entry_date < v_cutover_date THEN
      IF NOT p_dry_run THEN
        UPDATE comp_recap
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover archive - not posted to GL]'
        WHERE id = v_id;
      END IF;
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      CONTINUE;
    END IF;
    
    v_is_deduction := (v_comp_category IS NOT NULL AND v_comp_category LIKE 'deduction_%');
    
    IF v_is_deduction THEN
      SELECT coa.id, coa.account_name INTO v_target_account_id, v_target_account_name
      FROM comp_deduction_map m
      JOIN chart_of_accounts coa 
        ON coa.agency_id = m.agency_id
        AND coa.chart_namespace = v_chart_namespace
        AND coa.account_name = m.source_account_name
        AND coa.parent_account_id = (
          SELECT p.id FROM chart_of_accounts p 
          WHERE p.agency_id = m.agency_id AND p.chart_namespace = v_chart_namespace 
            AND p.account_name = m.source_parent_account_name AND p.parent_account_id IS NULL
        )
      WHERE m.agency_id = p_agency_id AND m.comp_category = v_comp_category AND m.is_active = TRUE
        AND (m.description_pattern IS NULL 
             OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    ELSE
      SELECT coa.id, coa.account_name INTO v_target_account_id, v_target_account_name
      FROM comp_category_map m
      JOIN chart_of_accounts coa 
        ON coa.agency_id = m.agency_id AND coa.chart_namespace = v_chart_namespace
        AND coa.account_name = m.source_account_name
        AND (
          (coa.parent_account_id IS NULL AND coa.account_name = m.source_parent_account_name)
          OR coa.parent_account_id = v_sf_parent_id
        )
      WHERE m.agency_id = p_agency_id AND m.comp_category = v_comp_category AND m.is_active = TRUE
        AND (m.description_pattern IS NULL
             OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    END IF;
    
    IF v_target_account_id IS NULL THEN
      v_target_account_id := v_suspense_id;
      v_target_account_name := 'Suspense (split offset pending)';
      v_classification_status := 'pending_review';
      v_suspense_reason := CASE 
        WHEN v_is_deduction THEN 'deduction unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
        ELSE 'revenue unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
      END;
    ELSE
      v_classification_status := 'classified';
    END IF;
    
    DECLARE
      v_dr_account_id uuid;
      v_cr_account_id uuid;
      v_dr_name text;
      v_cr_name text;
      v_je_desc text;
      v_abs_amount numeric := abs(v_amount);
    BEGIN
      IF v_is_deduction THEN
        v_dr_account_id := v_target_account_id; v_cr_account_id := v_cash_acct_id;
        v_dr_name := v_target_account_name; v_cr_name := v_cash_acct_name;
      ELSE
        IF v_amount > 0 THEN
          v_dr_account_id := v_cash_acct_id; v_cr_account_id := v_target_account_id;
          v_dr_name := v_cash_acct_name; v_cr_name := v_target_account_name;
        ELSE
          v_dr_account_id := v_target_account_id; v_cr_account_id := v_cash_acct_id;
          v_dr_name := v_target_account_name; v_cr_name := v_cash_acct_name;
        END IF;
      END IF;
      
      v_je_desc := COALESCE(v_description, COALESCE(v_comp_type, '') || ' ' || COALESCE(v_comp_category, ''));
      
      IF p_dry_run THEN
        v_posted_runs := v_posted_runs || jsonb_build_object(
          'comp_recap_id', v_id, 'entry_date', v_entry_date,
          'comp_category', v_comp_category, 'amount', v_amount,
          'is_deduction', v_is_deduction, 'description', LEFT(v_description, 60),
          'dr_account', v_dr_name, 'cr_account', v_cr_name,
          'classification_status', v_classification_status, 'suspense_reason', v_suspense_reason
        );
        IF v_classification_status = 'pending_review' THEN v_count_posted_susp := v_count_posted_susp + 1;
        ELSIF v_is_deduction THEN 
          v_count_posted_ded := v_count_posted_ded + 1;
          v_total_deductions := v_total_deductions + v_abs_amount;
        ELSE
          v_count_posted_rev := v_count_posted_rev + 1;
          v_total_revenue := v_total_revenue + v_abs_amount;
        END IF;
        CONTINUE;
      END IF;
      
      INSERT INTO journal_entries (
        agency_id, entry_date, entry_type, source, description,
        reference_number, classification_status, suspense_reason,
        classified_by, classified_at, created_by, created_at
      ) VALUES (
        p_agency_id, v_entry_date,
        CASE WHEN v_is_deduction THEN 'comp_deduction' ELSE 'comp_revenue' END,
        'gl_entry_writer', v_je_desc, 'comp_recap:' || v_id::text,
        v_classification_status, v_suspense_reason,
        CASE WHEN v_classification_status = 'classified' THEN 'comp_map' ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        'gl_entry_writer', NOW()
      ) RETURNING id INTO v_je_id;
      
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, created_at)
      VALUES (v_je_id, p_agency_id, v_dr_account_id, v_abs_amount, 0, LEFT(v_je_desc, 200), NOW());
      
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, created_at)
      VALUES (v_je_id, p_agency_id, v_cr_account_id, 0, v_abs_amount, LEFT(v_je_desc, 200), NOW());
      
      -- Back-reference for traceability
      UPDATE comp_recap 
      SET posted_at = NOW(),
          journal_entry_id = v_je_id,
          notes = COALESCE(notes, '') || ' [posted by gl_entry_writer ' || NOW()::text || 
                  CASE WHEN v_classification_status = 'pending_review' 
                       THEN '; suspense: ' || COALESCE(v_suspense_reason, '') ELSE '' END || ']'
      WHERE id = v_id;
      
      IF v_classification_status = 'pending_review' THEN v_count_posted_susp := v_count_posted_susp + 1;
      ELSIF v_is_deduction THEN 
        v_count_posted_ded := v_count_posted_ded + 1;
        v_total_deductions := v_total_deductions + v_abs_amount;
      ELSE 
        v_count_posted_rev := v_count_posted_rev + 1;
        v_total_revenue := v_total_revenue + v_abs_amount;
      END IF;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'ok', TRUE, 'dry_run', p_dry_run, 'cutover_date', v_cutover_date,
    'eligible', v_count_eligible, 'skipped_pre_cutover', v_count_skipped_cutover,
    'posted_revenue', v_count_posted_rev, 'posted_deduction', v_count_posted_ded,
    'posted_suspense', v_count_posted_susp, 'errors', v_count_errored,
    'total_revenue', v_total_revenue, 'total_deductions', v_total_deductions,
    'net_cash_impact', v_total_revenue - v_total_deductions,
    'error_details', v_errors
  );
END;
$function$
;

-- payroll_gl_writer
CREATE OR REPLACE FUNCTION public.payroll_gl_writer(p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cutover_date date;
  v_chart_namespace text;
  v_payroll_expense_account_name text;
  v_intercompany_account_name text;
  
  v_payroll_expense_account_id uuid;
  v_intercompany_account_id uuid;
  v_team_parent_id uuid;
  
  v_run_id uuid;
  v_pay_date date;
  v_pay_period_start date;
  v_pay_period_end date;
  v_gross_payroll numeric;
  v_employer_taxes numeric;
  v_payroll_provider text;
  v_posted_at timestamptz;
  v_existing_je_id uuid;
  
  v_je_id uuid;
  
  v_count_eligible int := 0;
  v_count_skipped_cutover int := 0;
  v_count_skipped_already_posted int := 0;
  v_count_posted int := 0;
  v_count_errored int := 0;
  
  v_total_expense numeric := 0;
  v_errors jsonb := '[]'::jsonb;
  v_posted_runs jsonb := '[]'::jsonb;
  v_dr_amount numeric;
  v_cr_amount numeric;
  v_description text;
BEGIN
  -- Load settings
  SELECT setting_value::date INTO v_cutover_date
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '2026-05-01'::date; END IF;
  
  SELECT setting_value INTO v_chart_namespace
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN v_chart_namespace := 'historical'; END IF;
  
  SELECT setting_value INTO v_payroll_expense_account_name
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_payroll_expense_account_name';
  IF v_payroll_expense_account_name IS NULL THEN v_payroll_expense_account_name := 'Payroll Costs'; END IF;
  
  SELECT setting_value INTO v_intercompany_account_name
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_intercompany_paypernewt_account_name';
  IF v_intercompany_account_name IS NULL THEN v_intercompany_account_name := 'Due to PaperNewt LLC (intercompany)'; END IF;
  
  -- Resolve intercompany account
  SELECT id INTO v_intercompany_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND account_name = v_intercompany_account_name
      AND parent_account_id IS NULL
    LIMIT 1;
  
  IF v_intercompany_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'intercompany_account_not_found',
      'searched_for', v_intercompany_account_name, 'namespace', v_chart_namespace);
  END IF;
  
  -- Resolve TEAM parent
  SELECT id INTO v_team_parent_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND account_name LIKE '0002 TEAM%'
      AND parent_account_id IS NULL
    LIMIT 1;
  
  IF v_team_parent_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'team_parent_not_found');
  END IF;
  
  -- Resolve Payroll Costs sub-account
  SELECT id INTO v_payroll_expense_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND parent_account_id = v_team_parent_id
      AND account_name = v_payroll_expense_account_name
    LIMIT 1;
  
  IF v_payroll_expense_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'payroll_expense_account_not_found',
      'searched_for', v_payroll_expense_account_name);
  END IF;
  
  -- Walk payroll_runs using explicit FOR loop with scalar variables
  FOR v_run_id, v_pay_date, v_pay_period_start, v_pay_period_end,
      v_gross_payroll, v_employer_taxes, v_payroll_provider, v_posted_at, v_existing_je_id IN
    SELECT id, pay_date, pay_period_start, pay_period_end, 
           gross_payroll, employer_taxes, payroll_provider, posted_at, journal_entry_id
    FROM payroll_runs 
    WHERE agency_id = p_agency_id
    ORDER BY pay_date
  LOOP
    v_count_eligible := v_count_eligible + 1;
    
    -- Cutover gate
    IF v_pay_date < v_cutover_date THEN
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      IF NOT p_dry_run AND v_posted_at IS NULL THEN
        UPDATE payroll_runs
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover; no JE posted per accounting_rules]'
        WHERE id = v_run_id;
      END IF;
      CONTINUE;
    END IF;
    
    -- Already posted
    IF v_posted_at IS NOT NULL AND v_existing_je_id IS NOT NULL THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1;
      CONTINUE;
    END IF;
    
    v_dr_amount := COALESCE(v_gross_payroll, 0) + COALESCE(v_employer_taxes, 0);
    v_cr_amount := v_dr_amount;
    v_description := 'Payroll run ' || v_pay_period_start || ' to ' || v_pay_period_end || 
                     ' (check ' || v_pay_date || ') — ' || COALESCE(v_payroll_provider, 'Payroll');
    
    IF v_dr_amount <= 0 THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object('run_id', v_run_id, 'reason', 'zero_or_negative_amount');
      CONTINUE;
    END IF;
    
    IF p_dry_run THEN
      v_posted_runs := v_posted_runs || jsonb_build_object(
        'run_id', v_run_id,
        'pay_date', v_pay_date,
        'dr_payroll_expense', v_dr_amount,
        'cr_intercompany', v_cr_amount,
        'description', v_description
      );
      v_count_posted := v_count_posted + 1;
      v_total_expense := v_total_expense + v_dr_amount;
      CONTINUE;
    END IF;
    
    -- Insert JE
    INSERT INTO journal_entries (
      agency_id, entry_date, description, source, reference_number,
      classification_status, created_at
    ) VALUES (
      p_agency_id, v_pay_date, v_description,
      'payroll_gl_writer', 'PAYROLL-' || v_run_id::text,
      'classified', NOW()
    ) RETURNING id INTO v_je_id;
    
    INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
    VALUES (v_je_id, p_agency_id, v_payroll_expense_account_id, v_dr_amount, 0,
            'Gross payroll $' || v_gross_payroll::text || ' + ER taxes $' || v_employer_taxes::text);
    
    INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
    VALUES (v_je_id, p_agency_id, v_intercompany_account_id, 0, v_cr_amount,
            'Owed to PaperNewt LLC for ' || v_pay_period_start || ' to ' || v_pay_period_end);
    
    UPDATE payroll_runs
    SET posted_at = NOW(),
        journal_entry_id = v_je_id,
        notes = COALESCE(notes, '') || ' [posted by payroll_gl_writer ' || NOW()::text || ']'
    WHERE id = v_run_id;
    
    v_count_posted := v_count_posted + 1;
    v_total_expense := v_total_expense + v_dr_amount;
    v_posted_runs := v_posted_runs || jsonb_build_object(
      'run_id', v_run_id, 'pay_date', v_pay_date,
      'je_id', v_je_id, 'dr', v_dr_amount, 'cr', v_cr_amount
    );
  END LOOP;
  
  RETURN jsonb_build_object(
    'ok', TRUE,
    'dry_run', p_dry_run,
    'cutover_date', v_cutover_date,
    'eligible', v_count_eligible,
    'skipped_pre_cutover', v_count_skipped_cutover,
    'skipped_already_posted', v_count_skipped_already_posted,
    'posted', v_count_posted,
    'errors', v_count_errored,
    'total_payroll_expense_posted', v_total_expense,
    'posted_runs', v_posted_runs,
    'error_details', v_errors,
    'accounts_used', jsonb_build_object(
      'dr_expense', v_payroll_expense_account_name,
      'cr_intercompany', v_intercompany_account_name
    )
  );
END;
$function$
;


COMMIT;
