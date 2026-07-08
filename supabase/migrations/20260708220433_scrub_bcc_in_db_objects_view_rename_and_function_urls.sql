-- Tier 3: DB objects scrub
-- (a) Rename source_bucket value 'bcc_originating' → 'newtworks_originating' in v_trial_balance
-- (b) Drop + recreate v_variance_books_historical_vs_bcc as v_variance_books_historical_vs_newtworks
--     with column bcc_balance → newtworks_balance and CTE bcc_data → newtworks_data
-- NOTE: chart_namespace = 'bcc_sf' data + column default LEFT AS-IS pending Peter's decision.

-- =========================================================================
-- (a) v_trial_balance: change 'bcc_originating' → 'newtworks_originating'
-- =========================================================================
CREATE OR REPLACE VIEW public.v_trial_balance AS
 SELECT je.agency_id,
    coa.id AS account_id,
    coa.account_code,
    coa.account_name,
    coa.account_type,
    coa.parent_account_id,
    parent.account_name AS parent_account_name,
        CASE
            WHEN je.source ~~ 'books_historical_import%'::text THEN 'books_historical'::text
            WHEN je.source = ANY (ARRAY['gl_entry_writer'::text, 'payroll_gl_writer'::text, 'bank_gl_writer'::text, 'cc_gl_writer'::text, 'document_processor'::text, 'document_processor_drainer'::text, 'claude_adjustment'::text]) THEN 'newtworks_originating'::text
            ELSE 'other'::text
        END AS source_bucket,
    date_trunc('month'::text, je.entry_date::timestamp with time zone)::date AS month_start,
    je.entry_date,
    sum(jl.debit) AS total_debit,
    sum(jl.credit) AS total_credit,
        CASE
            WHEN coa.account_type = 'income'::text AND je.source ~~ 'books_historical_import%'::text THEN sum(jl.debit) - sum(jl.credit)
            WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text]) THEN sum(jl.debit) - sum(jl.credit)
            ELSE sum(jl.credit) - sum(jl.debit)
        END AS net_balance,
    count(DISTINCT je.id) AS entry_count
   FROM journal_entries je
     JOIN journal_lines jl ON jl.journal_entry_id = je.id
     JOIN chart_of_accounts coa ON coa.id = jl.account_id
     LEFT JOIN chart_of_accounts parent ON parent.id = coa.parent_account_id
  GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name, coa.account_type, coa.parent_account_id, parent.account_name, je.source, (date_trunc('month'::text, je.entry_date::timestamp with time zone)), je.entry_date;

-- =========================================================================
-- (b) Drop old variance view, create new with renamed column + CTE
-- =========================================================================
DROP VIEW IF EXISTS public.v_variance_books_historical_vs_bcc;

CREATE VIEW public.v_variance_books_historical_vs_newtworks AS
 WITH books_historical_data AS (
         SELECT v_trial_balance.agency_id,
            v_trial_balance.account_id,
            v_trial_balance.account_code,
            v_trial_balance.account_name,
            v_trial_balance.account_type,
            v_trial_balance.parent_account_name,
            v_trial_balance.month_start,
            sum(v_trial_balance.net_balance) AS books_historical_balance,
            sum(v_trial_balance.total_debit) AS books_historical_debit,
            sum(v_trial_balance.total_credit) AS books_historical_credit
           FROM v_trial_balance
          WHERE v_trial_balance.source_bucket = 'books_historical'::text
          GROUP BY v_trial_balance.agency_id, v_trial_balance.account_id, v_trial_balance.account_code, v_trial_balance.account_name, v_trial_balance.account_type, v_trial_balance.parent_account_name, v_trial_balance.month_start
        ), newtworks_data AS (
         SELECT v_trial_balance.agency_id,
            v_trial_balance.account_id,
            v_trial_balance.account_code,
            v_trial_balance.account_name,
            v_trial_balance.account_type,
            v_trial_balance.parent_account_name,
            v_trial_balance.month_start,
            sum(v_trial_balance.net_balance) AS newtworks_balance,
            sum(v_trial_balance.total_debit) AS newtworks_debit,
            sum(v_trial_balance.total_credit) AS newtworks_credit
           FROM v_trial_balance
          WHERE v_trial_balance.source_bucket = 'newtworks_originating'::text
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
    COALESCE(h.books_historical_balance, 0::numeric) AS books_historical_balance,
    COALESCE(b.newtworks_balance, 0::numeric) AS newtworks_balance,
    COALESCE(b.newtworks_balance, 0::numeric) - COALESCE(h.books_historical_balance, 0::numeric) AS variance,
        CASE
            WHEN COALESCE(h.books_historical_balance, 0::numeric) = 0::numeric AND COALESCE(b.newtworks_balance, 0::numeric) = 0::numeric THEN 0::numeric
            WHEN COALESCE(h.books_historical_balance, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE round((COALESCE(b.newtworks_balance, 0::numeric) - COALESCE(h.books_historical_balance, 0::numeric)) / abs(h.books_historical_balance) * 100::numeric, 1)
        END AS variance_pct
   FROM books_historical_data h
     FULL JOIN newtworks_data b ON h.agency_id = b.agency_id AND h.account_id = b.account_id AND h.month_start = b.month_start;
