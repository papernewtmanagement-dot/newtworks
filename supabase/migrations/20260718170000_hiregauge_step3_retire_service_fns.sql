-- HireGauge Step 3: retire cts_service_os / cts_service_sales_os (+ their competencies + adjusted variants)
-- Rebuild cts_all_competencies against 7-role model (debug/inspection helper).
--
-- Consumer audit (2026-07-18):
--   DB callers of cts_service_os / cts_service_sales_os / their _competencies / _adjusted:
--     cts_all_competencies (updated in this migration)
--   Repo callers (GitHub search API): NONE for any of the 6 legacy fns
--   Repo callers of cts_all_competencies itself: NONE
--   → cts_all_competencies has zero external consumers; rebuild vs drop is discretionary.
--     Kept as a debugging/inspection helper (Peter uses this format for cohort walkthroughs).
--
-- Non-additive: 6 DROP FUNCTIONs + one CREATE OR REPLACE (shape changes: 8-key jsonb → 14-key jsonb).

------------------------------------------------------------
-- 1. Rebuild cts_all_competencies for 7-role model
------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cts_all_competencies(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT jsonb_build_object(
    -- Unadjusted (raw regression from traits)
    'sales_outbound', public.cts_sales_outbound_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'sales_inbound', public.cts_sales_inbound_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'sales_in_book', public.cts_sales_in_book_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'retention_reception', public.cts_retention_reception_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'retention_escalation', public.cts_retention_escalation_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'retention_support', public.cts_retention_support_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),
    'aspirant', public.cts_aspirant_competencies(
      ta.deadline_motivation, ta.recognition_drive, ta.assertiveness,
      ta.independent_spirit, ta.analytical, ta.compassion,
      ta.self_promotion, ta.belief_in_others, ta.optimism),

    -- Adjusted (distortion-dampened + LSS-modified + reliability-regressed)
    'sales_outbound_adjusted',       public.cts_sales_outbound_competencies_adjusted(p_assessment_id),
    'sales_inbound_adjusted',        public.cts_sales_inbound_competencies_adjusted(p_assessment_id),
    'sales_in_book_adjusted',        public.cts_sales_in_book_competencies_adjusted(p_assessment_id),
    'retention_reception_adjusted',  public.cts_retention_reception_competencies_adjusted(p_assessment_id),
    'retention_escalation_adjusted', public.cts_retention_escalation_competencies_adjusted(p_assessment_id),
    'retention_support_adjusted',    public.cts_retention_support_competencies_adjusted(p_assessment_id),
    'aspirant_adjusted',             public.cts_aspirant_competencies_adjusted(p_assessment_id)
  )
  FROM public.hiring_candidates ta
  WHERE ta.id = p_assessment_id
    AND ta.deadline_motivation IS NOT NULL;
$function$;

------------------------------------------------------------
-- 2. Drop 6 legacy functions (retired)
------------------------------------------------------------
DROP FUNCTION IF EXISTS public.cts_service_os                            (integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.cts_service_sales_os                      (integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.cts_service_competencies                  (integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.cts_service_sales_competencies            (integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.cts_service_competencies_adjusted         (uuid);
DROP FUNCTION IF EXISTS public.cts_service_sales_competencies_adjusted   (uuid);
