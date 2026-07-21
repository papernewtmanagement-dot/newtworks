-- Migration 20260721012711 (mirror of applied migration)
-- Strip _meta from each role's output in cts_all_competencies.
-- Frontend CandidateDetail.jsx iterates Object.entries(competencies[role]) and hands each value
-- to AssessRow expecting a scalar integer. The _meta key holds a nested object (has_lss, acc_flags,
-- reliability, distortion, etc.) which React can't render — throws Minified React error #31.
--
-- _meta remains accessible via direct calls to the _adjusted fns for debugging/introspection.
-- Only cts_all_competencies (the frontend-facing aggregator) strips it.

CREATE OR REPLACE FUNCTION public.cts_all_competencies(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT jsonb_build_object(
    'sales_outbound',       public.cts_sales_outbound_competencies_adjusted(p_assessment_id)       - '_meta',
    'sales_inbound',        public.cts_sales_inbound_competencies_adjusted(p_assessment_id)        - '_meta',
    'sales_in_book',        public.cts_sales_in_book_competencies_adjusted(p_assessment_id)        - '_meta',
    'retention_reception',  public.cts_retention_reception_competencies_adjusted(p_assessment_id)  - '_meta',
    'retention_escalation', public.cts_retention_escalation_competencies_adjusted(p_assessment_id) - '_meta',
    'retention_support',    public.cts_retention_support_competencies_adjusted(p_assessment_id)    - '_meta',
    'aspirant',             public.cts_aspirant_competencies_adjusted(p_assessment_id)             - '_meta'
  );
$function$;

COMMENT ON FUNCTION public.cts_all_competencies IS
  'Returns adjusted (LSS v4 asymmetric + reliability + distortion) competency scores for all 7 roles as flat competency->integer maps. _meta stripped per-role for React iteration compatibility — access _meta via direct cts_*_competencies_adjusted fns if needed. Frontend CandidateDetail assessment expanded section reads competencies[role] as flat map.';
