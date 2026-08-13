-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-27 21:39:11 UTC (ledger name: rewrite_v_growth_budget_licensing_ytd_drop_chart_namespace) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260727213911.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE VIEW public.v_growth_budget_licensing_ytd AS
SELECT jl.agency_id,
    a.account_code,
    a.account_name,
    (date_trunc('year'::text, COALESCE((je.entry_date)::timestamp with time zone, jl.created_at)))::date AS year_start,
    round(sum((COALESCE(jl.debit, (0)::numeric) - COALESCE(jl.credit, (0)::numeric))), 2) AS licensing_ytd_dollars,
    count(*) AS entry_count,
    jsonb_agg(jsonb_build_object('journal_entry_id', jl.journal_entry_id, 'entry_date', je.entry_date, 'debit', jl.debit, 'credit', jl.credit, 'description', jl.description) ORDER BY je.entry_date DESC) AS entries
   FROM ((journal_lines jl
     JOIN chart_of_accounts a ON ((a.id = jl.account_id)))
     LEFT JOIN journal_entries je ON ((je.id = jl.journal_entry_id)))
  WHERE ((a.account_code = '6715'::text) AND (date_trunc('year'::text, COALESCE((je.entry_date)::timestamp with time zone, jl.created_at)) = date_trunc('year'::text, (CURRENT_DATE)::timestamp with time zone)))
  GROUP BY jl.agency_id, a.account_code, a.account_name, (date_trunc('year'::text, COALESCE((je.entry_date)::timestamp with time zone, jl.created_at)));
