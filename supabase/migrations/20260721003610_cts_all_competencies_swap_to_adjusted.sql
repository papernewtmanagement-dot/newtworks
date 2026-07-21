-- Migration 20260721003610 (mirror of applied migration)
-- Swap cts_all_competencies so base keys (sales_outbound, sales_inbound, etc.)
-- return the LSS-adjusted output (v4 asymmetric, per-competency weighted).
-- Drops the _adjusted-suffixed keys — no consumers (verified via frontend + DB grep).
--
-- Frontend reads competencies[currentSelected] where currentSelected is a base
-- role key. Before this migration, that pulled the unadjusted values and the
-- LSS-adjusted work was invisible. After this migration, base keys ARE the
-- adjusted (LSS + reliability + distortion) values.
--
-- Consumer audit 2026-07-20:
--   Frontend: only src/components/CandidateDetail.jsx line 1239 calls this fn,
--             reads competencies[currentSelected] (base keys only).
--   Edge fns / scripts: no references (repo grep).
--   DB fns: _hiregauge_get_trait_value calls the raw 9-arg cts_sales_outbound_competencies
--          directly, does not touch cts_all_competencies.

CREATE OR REPLACE FUNCTION public.cts_all_competencies(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT jsonb_build_object(
    'sales_outbound',       public.cts_sales_outbound_competencies_adjusted(p_assessment_id),
    'sales_inbound',        public.cts_sales_inbound_competencies_adjusted(p_assessment_id),
    'sales_in_book',        public.cts_sales_in_book_competencies_adjusted(p_assessment_id),
    'retention_reception',  public.cts_retention_reception_competencies_adjusted(p_assessment_id),
    'retention_escalation', public.cts_retention_escalation_competencies_adjusted(p_assessment_id),
    'retention_support',    public.cts_retention_support_competencies_adjusted(p_assessment_id),
    'aspirant',             public.cts_aspirant_competencies_adjusted(p_assessment_id)
  );
$function$;

COMMENT ON FUNCTION public.cts_all_competencies IS
  'Returns adjusted (LSS v4 asymmetric + reliability + distortion) competency scores for all 7 roles. Base keys hold adjusted output; _adjusted-suffixed keys removed 2026-07-20 (no consumers). Frontend CandidateDetail assessment expanded section reads competencies[role] flat map.';
