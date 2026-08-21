
CREATE OR REPLACE VIEW v_trial_balance AS
SELECT je.agency_id,
    coa.id AS account_id,
    coa.account_code,
    coa.account_name,
    coa.account_type,
    coa.parent_account_id,
    parent.account_name AS parent_account_name,
        CASE
            WHEN je.source ~~ 'books_historical_import%'::text THEN 'books_historical'::text
            WHEN je.source = ANY (ARRAY['gl_entry_writer'::text, 'payroll_gl_writer'::text, 'bank_gl_writer'::text, 'cc_gl_writer'::text, 'document_processor'::text, 'document_processor_drainer'::text]) THEN 'bcc_originating'::text
            ELSE 'other'::text
        END AS source_bucket,
    date_trunc('month'::text, je.entry_date::timestamp with time zone)::date AS month_start,
    je.entry_date,
    sum(jl.debit) AS total_debit,
    sum(jl.credit) AS total_credit,
        CASE
            -- legacy source historical income was exported DR-positive (sign-inverted at source).
            -- Flip ONLY income in the books_historical bucket so the P&L reads correctly,
            -- without modifying the verbatim historical journal lines.
            WHEN coa.account_type = 'income'::text AND je.source ~~ 'books_historical_import%'::text
                THEN sum(jl.debit) - sum(jl.credit)
            WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text])
                THEN sum(jl.debit) - sum(jl.credit)
            ELSE sum(jl.credit) - sum(jl.debit)
        END AS net_balance,
    count(DISTINCT je.id) AS entry_count
   FROM journal_entries je
     JOIN journal_lines jl ON jl.journal_entry_id = je.id
     JOIN chart_of_accounts coa ON coa.id = jl.account_id
     LEFT JOIN chart_of_accounts parent ON parent.id = coa.parent_account_id
  GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name, coa.account_type, coa.parent_account_id, parent.account_name,
        je.source,
        (date_trunc('month'::text, je.entry_date::timestamp with time zone)), je.entry_date;

