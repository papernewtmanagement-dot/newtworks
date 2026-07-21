-- Migration 20260721014306 (mirror of applied migration)
-- Drop three orphaned fns from the pre-per-competency-weights era.
-- Consumer audit 2026-07-21: zero DB callers (pg_get_functiondef grep), zero repo refs
-- (src/, supabase/functions/, scripts/ grep across all .ts/.js/.jsx).
--
-- Superseded by:
--   _cts_lss_modifier + _cts_finalize_competency → _cts_lss_apply_v4 (per-competency weighted)
--   cts_sales_competencies_lss_adjusted (17-arg v4)  → cts_sales_outbound/inbound/in_book_competencies_adjusted
--                                                       reading hiregauge_competencies

DROP FUNCTION IF EXISTS public._cts_lss_modifier(integer, integer);
DROP FUNCTION IF EXISTS public._cts_finalize_competency(integer, numeric, text);
DROP FUNCTION IF EXISTS public.cts_sales_competencies_lss_adjusted(
  integer, integer, integer, integer, integer, integer, integer, integer, integer,
  integer, integer, integer, integer, integer, integer, text, text
);
