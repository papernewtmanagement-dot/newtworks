-- Migration 20260721032545 (mirror of applied migration)
-- Rewire cts_all_competencies to hoist _lss_deltas to top-level (sibling to role keys).
-- Each role's flat map remains flat integers only (both _meta and _lss_deltas stripped from within).
-- Top-level shape:
--   { sales_outbound: {comp:int}, sales_inbound: {...}, ..., aspirant: {...},
--     _lss_deltas: { sales_outbound: {comp:delta}, sales_inbound: {...}, ..., aspirant: {...} } }
-- Frontend iterates competencies[role] safely (only integer keys). Reads competencies._lss_deltas[role][comp] for shading.

CREATE OR REPLACE FUNCTION public.cts_all_competencies(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH r AS (
    SELECT
      public.cts_sales_outbound_competencies_adjusted(p_assessment_id)       AS so,
      public.cts_sales_inbound_competencies_adjusted(p_assessment_id)        AS si,
      public.cts_sales_in_book_competencies_adjusted(p_assessment_id)        AS sib,
      public.cts_retention_reception_competencies_adjusted(p_assessment_id)  AS rr,
      public.cts_retention_escalation_competencies_adjusted(p_assessment_id) AS re,
      public.cts_retention_support_competencies_adjusted(p_assessment_id)    AS rs,
      public.cts_aspirant_competencies_adjusted(p_assessment_id)             AS asp
  )
  SELECT jsonb_build_object(
    'sales_outbound',       (so  - '_meta') - '_lss_deltas',
    'sales_inbound',        (si  - '_meta') - '_lss_deltas',
    'sales_in_book',        (sib - '_meta') - '_lss_deltas',
    'retention_reception',  (rr  - '_meta') - '_lss_deltas',
    'retention_escalation', (re  - '_meta') - '_lss_deltas',
    'retention_support',    (rs  - '_meta') - '_lss_deltas',
    'aspirant',             (asp - '_meta') - '_lss_deltas',
    '_lss_deltas', jsonb_build_object(
      'sales_outbound',       COALESCE(so  -> '_lss_deltas', '{}'::jsonb),
      'sales_inbound',        COALESCE(si  -> '_lss_deltas', '{}'::jsonb),
      'sales_in_book',        COALESCE(sib -> '_lss_deltas', '{}'::jsonb),
      'retention_reception',  COALESCE(rr  -> '_lss_deltas', '{}'::jsonb),
      'retention_escalation', COALESCE(re  -> '_lss_deltas', '{}'::jsonb),
      'retention_support',    COALESCE(rs  -> '_lss_deltas', '{}'::jsonb),
      'aspirant',             COALESCE(asp -> '_lss_deltas', '{}'::jsonb)
    )
  )
  FROM r;
$function$;

COMMENT ON FUNCTION public.cts_all_competencies IS
  'Returns adjusted (LSS v4 asymmetric + reliability + distortion) competency scores for all 7 roles as flat competency->integer maps. _meta and _lss_deltas stripped from each role for safe React iteration. Top-level _lss_deltas key exposes per-competency LSS deltas by role for the CandidateDetail assessment shading UI (dark tint = big boost, light = small, red = LSS dampened).';
