-- Migration 20260721225148 (mirror of applied migration)
-- v_hiring_candidates.assessment_nature = OS for hc.assessment_target_role.
-- When that column is NULL (never set on some candidates), the CASE falls through
-- to NULL::integer even though the candidate has full assessment data and a clear
-- best-fit role. Result: assessment_nature = NULL for John Kostov, Cassandra Alves,
-- Stephanie Rogers — despite having assessment_nurture and assessment_drivers populated.
-- Fix: COALESCE(hc.assessment_target_role, bf.best_role) — falls back to the best-fit
-- role's OS when no explicit target role is set. The same CASE appears twice in the
-- view (assessment_nature and inside assessment_composite); replace hits both.

DO $$
DECLARE
  view_body text;
  before_str text := 'CASE hc.assessment_target_role
            WHEN ''aspirant''::text THEN bf.aspirant_os
            WHEN ''sales_outbound''::text THEN bf.sales_outbound_os
            WHEN ''sales_inbound''::text THEN bf.sales_inbound_os
            WHEN ''sales_in_book''::text THEN bf.sales_in_book_os
            WHEN ''retention_reception''::text THEN bf.retention_reception_os
            WHEN ''retention_escalation''::text THEN bf.retention_escalation_os
            WHEN ''retention_support''::text THEN bf.retention_support_os
            ELSE NULL::integer
        END';
  after_str text := 'CASE COALESCE(hc.assessment_target_role, bf.best_role)
            WHEN ''aspirant''::text THEN bf.aspirant_os
            WHEN ''sales_outbound''::text THEN bf.sales_outbound_os
            WHEN ''sales_inbound''::text THEN bf.sales_inbound_os
            WHEN ''sales_in_book''::text THEN bf.sales_in_book_os
            WHEN ''retention_reception''::text THEN bf.retention_reception_os
            WHEN ''retention_escalation''::text THEN bf.retention_escalation_os
            WHEN ''retention_support''::text THEN bf.retention_support_os
            ELSE NULL::integer
        END';
BEGIN
  SELECT pg_get_viewdef('public.v_hiring_candidates'::regclass, true) INTO view_body;
  IF position(before_str in view_body) = 0 THEN
    RAISE EXCEPTION 'anchor not found in v_hiring_candidates viewdef';
  END IF;
  view_body := replace(view_body, before_str, after_str);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_hiring_candidates AS ' || view_body;
END $$;
