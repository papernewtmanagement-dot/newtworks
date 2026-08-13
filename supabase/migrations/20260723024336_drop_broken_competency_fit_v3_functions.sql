-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-23 02:43:36 UTC (ledger name: drop_broken_competency_fit_v3_functions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260723024336.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DROP FUNCTION IF EXISTS public.competency_fit_v3_sales_outbound(int,int,int,int,int,int,int,int,int);
DROP FUNCTION IF EXISTS public.competency_fit_v3_sales_inbound(int,int,int,int,int,int,int,int,int);
DROP FUNCTION IF EXISTS public.competency_fit_v3_sales_in_book(int,int,int,int,int,int,int,int,int);
DROP FUNCTION IF EXISTS public.competency_fit_v3_retention_reception(int,int,int,int,int,int,int,int,int);
DROP FUNCTION IF EXISTS public.competency_fit_v3_retention_escalation(int,int,int,int,int,int,int,int,int);
DROP FUNCTION IF EXISTS public.competency_fit_v3_retention_support(int,int,int,int,int,int,int,int,int);
DROP FUNCTION IF EXISTS public.competency_fit_v3_aspirant(int,int,int,int,int,int,int,int,int);
