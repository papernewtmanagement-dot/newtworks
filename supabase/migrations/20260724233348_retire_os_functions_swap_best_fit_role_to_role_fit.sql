-- Swap assessment_best_fit_role internals from *_os regressions to assessment_role_fit_<role>
-- fit_scores, then drop the seven *_os functions.
-- Return column names retained (<role>_os, best_os) for CandidateDetail.jsx compatibility;
-- values are now competency-weighted role_fit fit_scores, NOT vendor CTS OS regressions.

CREATE OR REPLACE FUNCTION public.assessment_best_fit_role(p_assessment_id uuid)
RETURNS TABLE(
  best_role text,
  best_role_category text,
  display_label text,
  best_os integer,
  sales_outbound_os integer,
  sales_inbound_os integer,
  sales_in_book_os integer,
  retention_reception_os integer,
  retention_escalation_os integer,
  retention_support_os integer,
  aspirant_os integer
)
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  t RECORD;
  s_so int; s_si int; s_sib int; s_rr int; s_re int; s_rs int; s_asp int;
  best_r text; best_o int;
  best_cat text; best_label text;
BEGIN
  SELECT deadline_motivation, optimism
  INTO t
  FROM public.hiring_candidates
  WHERE id = p_assessment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;

  IF t.deadline_motivation IS NULL OR t.optimism IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, NULL::text,
      NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int;
    RETURN;
  END IF;

  s_so  := NULLIF((public.assessment_role_fit_sales_outbound      (p_assessment_id) ->> 'fit_score'), '')::int;
  s_si  := NULLIF((public.assessment_role_fit_sales_inbound       (p_assessment_id) ->> 'fit_score'), '')::int;
  s_sib := NULLIF((public.assessment_role_fit_sales_in_book       (p_assessment_id) ->> 'fit_score'), '')::int;
  s_rr  := NULLIF((public.assessment_role_fit_retention_reception (p_assessment_id) ->> 'fit_score'), '')::int;
  s_re  := NULLIF((public.assessment_role_fit_retention_escalation(p_assessment_id) ->> 'fit_score'), '')::int;
  s_rs  := NULLIF((public.assessment_role_fit_retention_support   (p_assessment_id) ->> 'fit_score'), '')::int;
  s_asp := NULLIF((public.assessment_role_fit_aspirant            (p_assessment_id) ->> 'fit_score'), '')::int;

  best_o := GREATEST(s_so, s_si, s_sib, s_rr, s_re, s_rs, s_asp);

  best_r := CASE
    WHEN best_o = s_so  THEN 'sales_outbound'
    WHEN best_o = s_si  THEN 'sales_inbound'
    WHEN best_o = s_sib THEN 'sales_in_book'
    WHEN best_o = s_rr  THEN 'retention_reception'
    WHEN best_o = s_re  THEN 'retention_escalation'
    WHEN best_o = s_rs  THEN 'retention_support'
    ELSE 'aspirant'
  END;

  best_cat := CASE
    WHEN best_r IN ('sales_outbound','sales_inbound','sales_in_book') THEN 'sales'
    WHEN best_r IN ('retention_reception','retention_escalation','retention_support') THEN 'retention'
    ELSE 'aspirant'
  END;

  best_label := CASE best_r
    WHEN 'sales_outbound'       THEN 'Sales - Outbound'
    WHEN 'sales_inbound'        THEN 'Sales - Inbound'
    WHEN 'sales_in_book'        THEN 'Sales - In-Book'
    WHEN 'retention_reception'  THEN 'Retention - Reception'
    WHEN 'retention_escalation' THEN 'Retention - Escalation'
    WHEN 'retention_support'    THEN 'Retention - Support'
    ELSE 'Aspirant'
  END;

  RETURN QUERY SELECT
    best_r, best_cat, best_label, best_o,
    s_so, s_si, s_sib, s_rr, s_re, s_rs, s_asp;
END;
$fn$;

COMMENT ON FUNCTION public.assessment_best_fit_role(uuid) IS
'Best-fit role via argmax over the seven assessment_role_fit_<role>(uuid) functions (fit_score field). Return column names retained for consumer compatibility (<role>_os, best_os); values are competency-weighted role_fit fit_scores (v3.4+ realism tune), NOT vendor CTS regressions. Vendor OS regression functions dropped 2026-07-24.';

-- Drop the seven vendor OS regression functions
DROP FUNCTION public.assessment_sales_outbound_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION public.assessment_sales_inbound_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION public.assessment_sales_in_book_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION public.assessment_retention_reception_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION public.assessment_retention_escalation_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION public.assessment_retention_support_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
DROP FUNCTION public.assessment_aspirant_os(integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer,integer);
