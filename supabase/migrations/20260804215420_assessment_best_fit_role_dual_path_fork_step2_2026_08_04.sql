-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-04 21:54:20 UTC (ledger name: assessment_best_fit_role_dual_path_fork_step2_2026_08_04) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260804215420.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- STEP 2 of restoring dual-path assessment scoring.
--
-- assessment_best_fit_role was rewritten to be new-instrument-only: it hard
-- returns all NULLs when hiring_candidates.achievement_striving is NULL. Since
-- achievement_striving is only written by the NEW instrument's finalize path,
-- every candidate holding OLD-instrument trait data scored blank. That was a
-- replacement, not the dual path Peter instructed.
--
-- Fork added here. Signature is UNCHANGED on purpose -- v_hiring_candidates and
-- verdict_overall both resolve these column names by position/name, and a prior
-- rename of these exact columns blanked the view for ten minutes.
--
--   new facet data present (achievement_striving NOT NULL)
--        -> newtworks_role_fit_*  (unchanged from current behaviour)
--   old trait data present (deadline_motivation NOT NULL)
--        -> assessment_role_fit_* (restored in step 1)
--   neither -> all NULLs, as before
--
-- deadline_motivation is the correct old-path marker: it was the entry guard the
-- old role-fit functions themselves used. assertiveness and compassion are NOT
-- usable as markers -- those two columns serve BOTH instruments.
--
-- Gate columns (best_verdict_cap / best_hard_decline / best_churn_risk /
-- best_gates_fired) come back NULL on the old path. That is deliberate and
-- honest: the critical-floor, integrity and reasoning gates are properties of
-- the NEW instrument's competency layer and have no old-instrument equivalent.
-- The old instrument's own gating lives downstream in _hiregauge_lss_autopass,
-- which reads lss_total_accuracy and is populated for exactly these candidates.
-- Do NOT fabricate gate values here to make the two paths look symmetrical.
CREATE OR REPLACE FUNCTION public.assessment_best_fit_role(p_assessment_id uuid)
 RETURNS TABLE(best_role text, best_role_category text, display_label text, best_fit_score integer, sales_outbound_fit_score integer, sales_inbound_fit_score integer, sales_in_book_fit_score integer, retention_reception_fit_score integer, retention_escalation_fit_score integer, retention_support_fit_score integer, aspirant_fit_score integer, best_verdict_cap text, best_hard_decline boolean, best_churn_risk boolean, best_gates_fired jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_candidate hiring_candidates;
  v_path text;
  s_so jsonb; s_si jsonb; s_sib jsonb; s_rr jsonb; s_re jsonb; s_rs jsonb; s_asp jsonb;
  n_so int; n_si int; n_sib int; n_rr int; n_re int; n_rs int; n_asp int;
  best_r text; best_o int; best_gated jsonb;
  best_cat text; best_label text;
BEGIN
  SELECT * INTO v_candidate FROM public.hiring_candidates WHERE id = p_assessment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;

  v_path := CASE
    WHEN v_candidate.achievement_striving IS NOT NULL THEN 'v2'
    WHEN v_candidate.deadline_motivation  IS NOT NULL THEN 'v1'
    ELSE NULL
  END;

  IF v_path IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, NULL::text,
      NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int, NULL::int,
      NULL::text, NULL::boolean, NULL::boolean, NULL::jsonb;
    RETURN;
  END IF;

  IF v_path = 'v2' THEN
    s_so  := public.newtworks_role_fit_sales_outbound(v_candidate);
    s_si  := public.newtworks_role_fit_sales_inbound(v_candidate);
    s_sib := public.newtworks_role_fit_sales_in_book(v_candidate);
    s_rr  := public.newtworks_role_fit_retention_reception(v_candidate);
    s_re  := public.newtworks_role_fit_retention_escalation(v_candidate);
    s_rs  := public.newtworks_role_fit_retention_support(v_candidate);
    s_asp := public.newtworks_role_fit_aspirant(v_candidate);
  ELSE
    s_so  := public.assessment_role_fit_sales_outbound(p_assessment_id);
    s_si  := public.assessment_role_fit_sales_inbound(p_assessment_id);
    s_sib := public.assessment_role_fit_sales_in_book(p_assessment_id);
    s_rr  := public.assessment_role_fit_retention_reception(p_assessment_id);
    s_re  := public.assessment_role_fit_retention_escalation(p_assessment_id);
    s_rs  := public.assessment_role_fit_retention_support(p_assessment_id);
    s_asp := public.assessment_role_fit_aspirant(p_assessment_id);
  END IF;

  n_so  := ROUND((NULLIF(s_so ->>'fit_score',''))::numeric)::int;
  n_si  := ROUND((NULLIF(s_si ->>'fit_score',''))::numeric)::int;
  n_sib := ROUND((NULLIF(s_sib->>'fit_score',''))::numeric)::int;
  n_rr  := ROUND((NULLIF(s_rr ->>'fit_score',''))::numeric)::int;
  n_re  := ROUND((NULLIF(s_re ->>'fit_score',''))::numeric)::int;
  n_rs  := ROUND((NULLIF(s_rs ->>'fit_score',''))::numeric)::int;
  n_asp := ROUND((NULLIF(s_asp->>'fit_score',''))::numeric)::int;

  best_o := GREATEST(n_so, n_si, n_sib, n_rr, n_re, n_rs, n_asp);

  IF best_o IS NULL THEN
    RETURN QUERY SELECT NULL::text, NULL::text, NULL::text,
      NULL::int, n_so, n_si, n_sib, n_rr, n_re, n_rs, n_asp,
      NULL::text, NULL::boolean, NULL::boolean, NULL::jsonb;
    RETURN;
  END IF;

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
