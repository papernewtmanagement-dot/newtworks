-- Rename return columns on assessment_best_fit_role:
--   best_os              -> best_fit_score
--   <role>_os (7 cols)   -> <role>_fit_score
-- Names now mirror the source jsonb field on assessment_role_fit_<role>(uuid) which is `fit_score`.
-- Behavior unchanged.

DROP FUNCTION public.assessment_best_fit_role(uuid);

CREATE FUNCTION public.assessment_best_fit_role(p_assessment_id uuid)
RETURNS TABLE(
  best_role text,
  best_role_category text,
  display_label text,
  best_fit_score integer,
  sales_outbound_fit_score integer,
  sales_inbound_fit_score integer,
  sales_in_book_fit_score integer,
  retention_reception_fit_score integer,
  retention_escalation_fit_score integer,
  retention_support_fit_score integer,
  aspirant_fit_score integer
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
'Best-fit role via argmax over the seven assessment_role_fit_<role>(uuid) functions (fit_score field). Return columns: best_role slug, best_role_category (sales|retention|aspirant), display_label, best_fit_score = max fit_score, <role>_fit_score = per-role fit_score. Values sourced from role_fit competency-weighted model (v3.4+ realism tune).';
