-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-03 16:56:20 UTC (ledger name: hiregauge_competency_layer_step6_verdict_assembly_v2) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260803165620.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
DROP FUNCTION IF EXISTS public.assessment_best_fit_role(uuid);

CREATE OR REPLACE FUNCTION public.assessment_best_fit_role(p_assessment_id uuid)
 RETURNS TABLE(
   best_role text, best_role_category text, display_label text, best_fit_score integer,
   sales_outbound_fit_score integer, sales_inbound_fit_score integer, sales_in_book_fit_score integer,
   retention_reception_fit_score integer, retention_escalation_fit_score integer, retention_support_fit_score integer,
   aspirant_fit_score integer,
   best_verdict_cap text, best_hard_decline boolean, best_churn_risk boolean, best_gates_fired jsonb
 )
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_candidate hiring_candidates;
  s_so jsonb; s_si jsonb; s_sib jsonb; s_rr jsonb; s_re jsonb; s_rs jsonb; s_asp jsonb;
  n_so int; n_si int; n_sib int; n_rr int; n_re int; n_rs int; n_asp int;
  best_r text; best_o int; best_gated jsonb;
  best_cat text; best_label text;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_assessment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;

  IF v_candidate.achievement_striving IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, NULL::text,
      NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int,
      NULL::text, NULL::boolean, NULL::boolean, NULL::jsonb;
    RETURN;
  END IF;

  s_so  := public.newtworks_role_fit_sales_outbound(v_candidate);
  s_si  := public.newtworks_role_fit_sales_inbound(v_candidate);
  s_sib := public.newtworks_role_fit_sales_in_book(v_candidate);
  s_rr  := public.newtworks_role_fit_retention_reception(v_candidate);
  s_re  := public.newtworks_role_fit_retention_escalation(v_candidate);
  s_rs  := public.newtworks_role_fit_retention_support(v_candidate);
  s_asp := public.newtworks_role_fit_aspirant(v_candidate);

  n_so  := NULLIF(s_so ->>'fit_score','')::int;
  n_si  := NULLIF(s_si ->>'fit_score','')::int;
  n_sib := NULLIF(s_sib->>'fit_score','')::int;
  n_rr  := NULLIF(s_rr ->>'fit_score','')::int;
  n_re  := NULLIF(s_re ->>'fit_score','')::int;
  n_rs  := NULLIF(s_rs ->>'fit_score','')::int;
  n_asp := NULLIF(s_asp->>'fit_score','')::int;

  best_o := GREATEST(n_so, n_si, n_sib, n_rr, n_re, n_rs, n_asp);

  best_r := CASE
    WHEN best_o = n_so  THEN 'sales_outbound'
    WHEN best_o = n_si  THEN 'sales_inbound'
    WHEN best_o = n_sib THEN 'sales_in_book'
    WHEN best_o = n_rr  THEN 'retention_reception'
    WHEN best_o = n_re  THEN 'retention_escalation'
    WHEN best_o = n_rs  THEN 'retention_support'
    ELSE 'aspirant'
  END;

  best_gated := CASE best_r
    WHEN 'sales_outbound' THEN s_so WHEN 'sales_inbound' THEN s_si WHEN 'sales_in_book' THEN s_sib
    WHEN 'retention_reception' THEN s_rr WHEN 'retention_escalation' THEN s_re
    WHEN 'retention_support' THEN s_rs ELSE s_asp
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
    n_so, n_si, n_sib, n_rr, n_re, n_rs, n_asp,
    best_gated->>'verdict_cap',
    (best_gated->>'hard_decline')::boolean,
    (best_gated->>'churn_risk')::boolean,
    best_gated->'gates_fired';
END;
$function$;

COMMENT ON FUNCTION public.assessment_best_fit_role(uuid) IS
'Rewired 2026-08-03 (Step 6) to call the 12-competency newtworks_role_fit_*
functions (gated, includes Step 5 gates a-d) instead of the retired
assessment_role_fit_* functions. Entry guard now checks
achievement_striving instead of deadline_motivation/optimism. Output shape
preserved (all original columns unchanged) plus four additive columns
(best_verdict_cap, best_hard_decline, best_churn_risk, best_gates_fired)
for the winning role. assessment_nature/verdict_assessment/verdict_overall
need no changes -- they only ever read the original numeric columns.';
