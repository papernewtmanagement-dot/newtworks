
CREATE OR REPLACE VIEW v_income_statement AS
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
            -- legacy source historical income was exported DR-positive (sign-inverted at source).
            -- Flip income for the books_historical_import source so P&L reads correctly.
            WHEN coa.account_type = 'income'::text AND je.source ~~ 'books_historical_import%'::text
                THEN sum(jl.debit) - sum(jl.credit)
            WHEN coa.account_type = 'income'::text
                THEN sum(jl.credit) - sum(jl.debit)
            WHEN coa.account_type = 'expense'::text
                THEN sum(jl.debit) - sum(jl.credit)
            ELSE 0::numeric
        END AS amount
   FROM journal_lines jl
     JOIN journal_entries je ON je.id = jl.journal_entry_id
     JOIN chart_of_accounts coa ON coa.id = jl.account_id
  WHERE coa.account_type = ANY (ARRAY['income'::text, 'expense'::text])
  GROUP BY je.agency_id, je.entry_date, je.source, coa.id, coa.account_code, coa.account_name, coa.account_type, coa.account_subtype;

