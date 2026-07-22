-- Migration: HireGauge role_fit v2.2 cutover
-- 2026-07-22 (composed 2026-07-21 evening CT)
--
-- Cutover from v1 (staged 2026-07-21) to v2.2 (staged this session).
-- Consumer audit (in-session before this migration): zero DB / frontend /
-- edge-function consumers of cts_role_fit_<role> under either name. Rename is
-- safe. v2 was validated against 31-candidate cohort at 27/31 clean matches
-- (up from v1's 68%).
--
-- Steps (in order):
--   1. Archive v1 role fns: cts_role_fit_<role>(uuid) -> cts_role_fit_<role>_v1_archive(uuid).
--      7 fns. Bodies untouched (v1 is self-contained, no helper calls).
--   2. Create canonical helpers _cts_role_fit_gates + _cts_role_fit_apply_gates
--      using v2.2 helper bodies (with _v2 stripped from any internal refs).
--   3. Create canonical role fns cts_role_fit_<role> using v2.2 role bodies
--      (with _v2 stripped from helper calls, model tag aligned to v2_2).
--   4. Drop the _v2 shells: 7 role fns + 2 helpers. _cts_role_fit_contrib is
--      shared, version-agnostic, untouched.
--
-- Model tag alignment: v2.2 helper body correctly says
--   'competency_fit_v2_2_2026_07_21' (matches handoff canonical)
-- but the 7 v2.2 role bodies still say 'competency_fit_v2_2026_07_21' (v2.1
-- leftover). Cutover aligns all to the v2_2 canonical.

BEGIN;

-- ================================================================
-- STEP 1: Archive v1 (rename to _v1_archive)
-- ================================================================

ALTER FUNCTION public.cts_role_fit_aspirant(uuid)              RENAME TO cts_role_fit_aspirant_v1_archive;
ALTER FUNCTION public.cts_role_fit_retention_escalation(uuid)  RENAME TO cts_role_fit_retention_escalation_v1_archive;
ALTER FUNCTION public.cts_role_fit_retention_reception(uuid)   RENAME TO cts_role_fit_retention_reception_v1_archive;
ALTER FUNCTION public.cts_role_fit_retention_support(uuid)     RENAME TO cts_role_fit_retention_support_v1_archive;
ALTER FUNCTION public.cts_role_fit_sales_in_book(uuid)         RENAME TO cts_role_fit_sales_in_book_v1_archive;
ALTER FUNCTION public.cts_role_fit_sales_inbound(uuid)         RENAME TO cts_role_fit_sales_inbound_v1_archive;
ALTER FUNCTION public.cts_role_fit_sales_outbound(uuid)        RENAME TO cts_role_fit_sales_outbound_v1_archive;

-- ================================================================
-- STEP 2: Create canonical helpers
-- ================================================================

CREATE OR REPLACE FUNCTION public._cts_role_fit_gates(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $body$
  SELECT jsonb_build_object(
    'validity_dampen',   (reliability IN ('low','questionable') OR response_distortion IN ('moderate','elevated','high')),
    'shadow_read',       (
      independent_spirit < 15 AND
      ((CASE WHEN self_promotion >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN analytical >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN compassion >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN belief_in_others >= 85 THEN 1 ELSE 0 END)
       + (CASE WHEN optimism >= 85 THEN 1 ELSE 0 END)) >= 2
    ),
    'hollow_broadcast',  (optimism >= 85 AND compassion < 30 AND (deadline_motivation < 40 OR independent_spirit < 40)),
    'coo_fail',          (compassion < 30),
    'hwe_fail',          (deadline_motivation < 30 AND independent_spirit < 30),
    'pit_deficit',       (optimism < 30),
    -- v2.2: Unconscious Self-Promoter — needs recognition (RD >= 70) but self-reports as not
    -- self-promoting (SP <= 40); reliability=moderate/low confirms self-perception gap.
    -- Framework: false-completion claims, coaching-defensive, not self-aware.
    'unconscious_self_promoter', (
      recognition_drive >= 70 AND self_promotion <= 40 AND
      reliability IN ('low','moderate','questionable')
    ),
    -- v2.2: Analytical Executor — cold (Compassion < 30) but analytical+drive+optimism intact.
    -- Bridges Compassion floor via scripts + structure. Elevates sales/escalation CoO caps.
    'analytical_executor', (
      analytical >= 80 AND compassion < 30 AND
      deadline_motivation >= 50 AND independent_spirit >= 50 AND optimism >= 70
    ),
    'deadline_motivation', deadline_motivation,
    'reliability',       reliability,
    'distortion',        response_distortion
  )
  FROM public.hiring_candidates
  WHERE id = p_assessment_id;
$body$;

CREATE OR REPLACE FUNCTION public._cts_role_fit_apply_gates(
  p_assessment_id uuid,
  p_role text,
  p_raw_score numeric,
  p_floor_comp_cap numeric,
  p_floor_source text,
  p_floor_source_val numeric
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  gates jsonb;
  v_dampened numeric;
  v_after_comp_cap numeric;
  v_final numeric;
  v_adjustments jsonb := '[]'::jsonb;
  v_coo_cap numeric;
  v_hwe_cap numeric;
  v_pit_cap numeric;
  v_deadline_cap numeric := 999;
  v_analytical_executor_lift boolean;
BEGIN
  gates := public._cts_role_fit_gates(p_assessment_id);
  v_dampened := p_raw_score;
  v_analytical_executor_lift := (gates->>'analytical_executor')::boolean;

  IF (gates->>'validity_dampen')::boolean THEN
    v_dampened := v_dampened * 0.85;
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','validity_dampener','factor',0.85,
      'reliability', gates->>'reliability', 'distortion', gates->>'distortion'
    ));
  END IF;

  -- v2.2: Unconscious Self-Promoter dampener (softer than hollow_broadcast)
  IF (gates->>'unconscious_self_promoter')::boolean THEN
    v_dampened := v_dampened * 0.90;
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','unconscious_self_promoter','factor',0.90,
      'reason','RD >= 70 + SP <= 40 + reliability suspect (self-perception gap)'
    ));
  END IF;

  IF (gates->>'shadow_read')::boolean THEN
    v_dampened := v_dampened * 0.75;
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','shadow_read','factor',0.75,
      'reason','IS floor with 2+ ceilings on SP/AN/CO/BO/OP'
    ));
  END IF;

  IF (gates->>'hollow_broadcast')::boolean THEN
    v_dampened := v_dampened * 0.80;
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','hollow_broadcast','factor',0.80,
      'reason','Optimism ceiling + Compassion floor + engine collapse'
    ));
  END IF;

  v_after_comp_cap := LEAST(v_dampened, p_floor_comp_cap);

  -- v2.2: CoO caps with analytical_executor lift for scripted-warm roles
  IF p_role = 'sales_outbound' THEN
    v_coo_cap := CASE WHEN v_analytical_executor_lift THEN 65 ELSE 55 END;
    v_hwe_cap := 50; v_pit_cap := 55;
  ELSIF p_role = 'sales_inbound' THEN
    v_coo_cap := CASE WHEN v_analytical_executor_lift THEN 60 ELSE 50 END;
    v_hwe_cap := 50; v_pit_cap := 55;
  ELSIF p_role = 'sales_in_book' THEN
    v_coo_cap := CASE WHEN v_analytical_executor_lift THEN 65 ELSE 55 END;
    v_hwe_cap := 50; v_pit_cap := 55;
  ELSIF p_role = 'aspirant' THEN
    v_coo_cap := 45; v_hwe_cap := 50; v_pit_cap := 55;
    v_deadline_cap := (gates->>'deadline_motivation')::numeric + 15;
  ELSIF p_role = 'retention_reception' THEN
    v_coo_cap := 45; v_hwe_cap := 55; v_pit_cap := 55;
  ELSIF p_role = 'retention_escalation' THEN
    v_coo_cap := CASE WHEN v_analytical_executor_lift THEN 65 ELSE 55 END;
    v_hwe_cap := 55; v_pit_cap := 55;
  ELSIF p_role = 'retention_support' THEN
    v_coo_cap := 100; v_hwe_cap := 60; v_pit_cap := 100;
  ELSE
    v_coo_cap := 100; v_hwe_cap := 100; v_pit_cap := 100;
  END IF;

  v_final := v_after_comp_cap;

  IF (gates->>'coo_fail')::boolean AND v_coo_cap < 100 THEN
    IF v_coo_cap < v_final THEN
      v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
        'kind','concern_for_others_cap','cap',v_coo_cap,
        'reason', CASE WHEN v_analytical_executor_lift 
                       THEN 'raw Compassion < 30 (lifted by analytical_executor)' 
                       ELSE 'raw Compassion < 30' END
      ));
      v_final := v_coo_cap;
    END IF;
  END IF;

  IF (gates->>'hwe_fail')::boolean THEN
    IF v_hwe_cap < v_final THEN
      v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
        'kind','hwe_fail_cap','cap',v_hwe_cap,'reason','raw DM < 30 AND raw IS < 30'
      ));
      v_final := v_hwe_cap;
    END IF;
  END IF;

  IF (gates->>'pit_deficit')::boolean AND v_pit_cap < 100 THEN
    IF v_pit_cap < v_final THEN
      v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
        'kind','pit_deficit_cap','cap',v_pit_cap,'reason','raw Optimism < 30 (PIT poison risk)'
      ));
      v_final := v_pit_cap;
    END IF;
  END IF;

  IF p_role = 'aspirant' AND v_deadline_cap < v_final THEN
    v_adjustments := v_adjustments || jsonb_build_array(jsonb_build_object(
      'kind','aspirant_deadline_cap','cap',v_deadline_cap,
      'deadline_motivation',(gates->>'deadline_motivation')::numeric,
      'reason','owner-track drive requires sustained Deadline'
    ));
    v_final := v_deadline_cap;
  END IF;

  RETURN jsonb_build_object(
    'fit_score', GREATEST(0, LEAST(100, ROUND(v_final)))::int,
    'raw_score', ROUND(p_raw_score, 2),
    'dampened_score', ROUND(v_dampened, 2),
    'after_comp_cap', ROUND(v_after_comp_cap, 2),
    'floor_comp_cap', ROUND(p_floor_comp_cap, 2),
    'floor_source', p_floor_source,
    'floor_source_value', p_floor_source_val,
    'adjustments', v_adjustments,
    'gates', gates,
    'model', 'competency_fit_v2_2_2026_07_21'
  );
END;
$body$;

-- ================================================================
-- STEP 3: Create canonical role fns (7)
-- ================================================================

CREATE OR REPLACE FUNCTION public.cts_role_fit_sales_outbound(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_hr numeric; v_mha numeric; v_dcc numeric; v_pic numeric;
  v_ho numeric; v_ps numeric; v_ldn numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
BEGIN
  c := public.cts_sales_outbound_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'handles_rejection') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_outbound');
  END IF;
  m := c->'_meta';

  v_hr  := (c->>'handles_rejection')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_dcc := (c->>'dials_cold_calls')::numeric;
  v_pic := (c->>'prospects_in_community')::numeric;
  v_ho  := (c->>'handles_objections')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_hr*0.18 + v_mha*0.16 + v_dcc*0.14 + v_pic*0.12
         + v_ho*0.12 + v_ps*0.10 + v_ldn*0.08 + v_rc*0.05 + v_pit*0.05;

  IF v_hr <= v_mha THEN
    v_floor_src := 'handles_rejection'; v_floor_src_val := v_hr;
  ELSE
    v_floor_src := 'maintains_high_activity'; v_floor_src_val := v_mha;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'sales_outbound', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'sales_outbound',
    'contributions', jsonb_build_object(
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.18, true),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.16, true),
      'dials_cold_calls',          public._cts_role_fit_contrib(v_dcc, 0.14, false),
      'prospects_in_community',    public._cts_role_fit_contrib(v_pic, 0.12, false),
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.12, false),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.10, false),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.08, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.05, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.05, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_sales_outbound_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$body$;

CREATE OR REPLACE FUNCTION public.cts_role_fit_sales_inbound(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_rrw numeric; v_cc numeric; v_ho numeric; v_ps numeric; v_ldn numeric;
  v_mha numeric; v_hr numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
BEGIN
  c := public.cts_sales_inbound_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'rapid_rapport_warm') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_inbound');
  END IF;
  m := c->'_meta';

  v_rrw := (c->>'rapid_rapport_warm')::numeric;
  v_cc  := (c->>'cadence_compliance')::numeric;
  v_ho  := (c->>'handles_objections')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_hr  := (c->>'handles_rejection')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_rrw*0.20 + v_cc*0.16 + v_ho*0.14 + v_ps*0.14 + v_ldn*0.12
         + v_mha*0.08 + v_hr*0.06 + v_rc*0.05 + v_pit*0.05;

  IF v_rrw <= v_cc THEN
    v_floor_src := 'rapid_rapport_warm'; v_floor_src_val := v_rrw;
  ELSE
    v_floor_src := 'cadence_compliance'; v_floor_src_val := v_cc;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'sales_inbound', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'sales_inbound',
    'contributions', jsonb_build_object(
      'rapid_rapport_warm',        public._cts_role_fit_contrib(v_rrw, 0.20, true),
      'cadence_compliance',        public._cts_role_fit_contrib(v_cc,  0.16, true),
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.14, false),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.14, false),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.12, false),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.08, false),
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.06, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.05, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.05, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_sales_inbound_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$body$;

CREATE OR REPLACE FUNCTION public.cts_role_fit_sales_in_book(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_csi numeric; v_ldn numeric; v_rw numeric; v_ho numeric; v_ps numeric;
  v_mha numeric; v_hr numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
BEGIN
  c := public.cts_sales_in_book_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'cross_sell_instinct') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_in_book');
  END IF;
  m := c->'_meta';

  v_csi := (c->>'cross_sell_instinct')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_rw  := (c->>'retention_watchfulness')::numeric;
  v_ho  := (c->>'handles_objections')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_hr  := (c->>'handles_rejection')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_csi*0.20 + v_ldn*0.16 + v_rw*0.14 + v_ho*0.12 + v_ps*0.12
         + v_mha*0.08 + v_hr*0.06 + v_rc*0.06 + v_pit*0.06;

  IF v_csi <= v_ldn THEN
    v_floor_src := 'cross_sell_instinct'; v_floor_src_val := v_csi;
  ELSE
    v_floor_src := 'listens_discovers_needs'; v_floor_src_val := v_ldn;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'sales_in_book', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'sales_in_book',
    'contributions', jsonb_build_object(
      'cross_sell_instinct',       public._cts_role_fit_contrib(v_csi, 0.20, true),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.16, true),
      'retention_watchfulness',    public._cts_role_fit_contrib(v_rw,  0.14, false),
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.12, false),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.12, false),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.08, false),
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.06, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.06, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.06, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_sales_in_book_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$body$;

CREATE OR REPLACE FUNCTION public.cts_role_fit_aspirant(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_hr numeric; v_ho numeric; v_mha numeric; v_ps numeric;
  v_hes numeric; v_ldn numeric; v_pic numeric; v_dcc numeric;
  v_cfr numeric; v_fso numeric; v_bleh numeric; v_pit numeric; v_rc numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
BEGIN
  c := public.cts_aspirant_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'has_entrepreneurial_spirit') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'aspirant');
  END IF;
  m := c->'_meta';

  v_hr   := (c->>'handles_rejection')::numeric;
  v_ho   := (c->>'handles_objections')::numeric;
  v_mha  := (c->>'maintains_high_activity')::numeric;
  v_ps   := (c->>'presents_solutions')::numeric;
  v_hes  := (c->>'has_entrepreneurial_spirit')::numeric;
  v_ldn  := (c->>'listens_discovers_needs')::numeric;
  v_pic  := (c->>'prospects_in_community')::numeric;
  v_dcc  := (c->>'dials_cold_calls')::numeric;
  v_cfr  := (c->>'competes_for_recognition')::numeric;
  v_fso  := (c->>'is_fast_start_oriented')::numeric;
  v_bleh := (c->>'balances_logic_and_emotion_when_hiring')::numeric;
  v_pit  := (c->>'positively_influences_team')::numeric;
  v_rc   := (c->>'receives_coaching')::numeric;

  v_raw := v_hr*0.12 + v_ho*0.10 + v_mha*0.10 + v_ps*0.10
         + v_hes*0.10 + v_ldn*0.08 + v_pic*0.08 + v_dcc*0.06
         + v_cfr*0.06 + v_fso*0.06 + v_bleh*0.06 + v_pit*0.05 + v_rc*0.03;

  IF v_hes <= v_hr THEN
    v_floor_src := 'has_entrepreneurial_spirit'; v_floor_src_val := v_hes;
  ELSE
    v_floor_src := 'handles_rejection'; v_floor_src_val := v_hr;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'aspirant', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'aspirant',
    'contributions', jsonb_build_object(
      'handles_rejection',                     public._cts_role_fit_contrib(v_hr,   0.12, true),
      'handles_objections',                    public._cts_role_fit_contrib(v_ho,   0.10, false),
      'maintains_high_activity',               public._cts_role_fit_contrib(v_mha,  0.10, false),
      'presents_solutions',                    public._cts_role_fit_contrib(v_ps,   0.10, false),
      'has_entrepreneurial_spirit',            public._cts_role_fit_contrib(v_hes,  0.10, true),
      'listens_discovers_needs',               public._cts_role_fit_contrib(v_ldn,  0.08, false),
      'prospects_in_community',                public._cts_role_fit_contrib(v_pic,  0.08, false),
      'dials_cold_calls',                      public._cts_role_fit_contrib(v_dcc,  0.06, false),
      'competes_for_recognition',              public._cts_role_fit_contrib(v_cfr,  0.06, false),
      'is_fast_start_oriented',                public._cts_role_fit_contrib(v_fso,  0.06, false),
      'balances_logic_and_emotion_when_hiring',public._cts_role_fit_contrib(v_bleh, 0.06, false),
      'positively_influences_team',            public._cts_role_fit_contrib(v_pit,  0.05, false),
      'receives_coaching',                     public._cts_role_fit_contrib(v_rc,   0.03, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_aspirant_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$body$;

CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_reception(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_rrw numeric; v_ldn numeric; v_cul numeric; v_rj numeric; v_pcn numeric;
  v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
BEGIN
  c := public.cts_retention_reception_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'rapid_rapport_warm') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_reception');
  END IF;
  m := c->'_meta';

  v_rrw := (c->>'rapid_rapport_warm')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_cul := (c->>'composure_under_load')::numeric;
  v_rj  := (c->>'routing_judgment')::numeric;
  v_pcn := (c->>'pivots_to_customer_need')::numeric;
  v_mdq := (c->>'makes_decisions_quickly')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_rrw*0.18 + v_ldn*0.16 + v_cul*0.14 + v_rj*0.14 + v_pcn*0.12
         + v_mdq*0.10 + v_rc*0.08 + v_pit*0.08;

  IF v_rrw <= v_cul THEN
    v_floor_src := 'rapid_rapport_warm'; v_floor_src_val := v_rrw;
  ELSE
    v_floor_src := 'composure_under_load'; v_floor_src_val := v_cul;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'retention_reception', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'retention_reception',
    'contributions', jsonb_build_object(
      'rapid_rapport_warm',        public._cts_role_fit_contrib(v_rrw, 0.18, true),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.16, false),
      'composure_under_load',      public._cts_role_fit_contrib(v_cul, 0.14, true),
      'routing_judgment',          public._cts_role_fit_contrib(v_rj,  0.14, false),
      'pivots_to_customer_need',   public._cts_role_fit_contrib(v_pcn, 0.12, false),
      'makes_decisions_quickly',   public._cts_role_fit_contrib(v_mdq, 0.10, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.08, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.08, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_retention_reception_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$body$;

CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_escalation(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_ho numeric; v_ldn numeric; v_rw numeric; v_ptd numeric; v_cul numeric;
  v_ps numeric; v_hr numeric; v_mha numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
BEGIN
  c := public.cts_retention_escalation_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'handles_objections') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_escalation');
  END IF;
  m := c->'_meta';

  v_ho  := (c->>'handles_objections')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_rw  := (c->>'retention_watchfulness')::numeric;
  v_ptd := (c->>'proactive_touch_discipline')::numeric;
  v_cul := (c->>'composure_under_load')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_hr  := (c->>'handles_rejection')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_ho*0.16 + v_ldn*0.12 + v_rw*0.14 + v_ptd*0.14 + v_cul*0.14
         + v_ps*0.10 + v_hr*0.06 + v_mha*0.04 + v_rc*0.05 + v_pit*0.05;

  IF v_ho <= v_cul THEN
    v_floor_src := 'handles_objections'; v_floor_src_val := v_ho;
  ELSE
    v_floor_src := 'composure_under_load'; v_floor_src_val := v_cul;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'retention_escalation', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'retention_escalation',
    'contributions', jsonb_build_object(
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.16, true),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.12, false),
      'retention_watchfulness',    public._cts_role_fit_contrib(v_rw,  0.14, false),
      'proactive_touch_discipline',public._cts_role_fit_contrib(v_ptd, 0.14, false),
      'composure_under_load',      public._cts_role_fit_contrib(v_cul, 0.14, true),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.10, false),
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.06, false),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.04, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.05, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.05, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_retention_escalation_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$body$;

CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_support(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $body$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_ad numeric; v_qtd numeric; v_wwcs numeric; v_mte numeric;
  v_an numeric; v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
BEGIN
  c := public.cts_retention_support_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'attention_to_detail') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_support');
  END IF;
  m := c->'_meta';

  v_ad   := (c->>'attention_to_detail')::numeric;
  v_qtd  := (c->>'queue_throughput_discipline')::numeric;
  v_wwcs := (c->>'works_without_close_supervision')::numeric;
  v_mte  := (c->>'manages_time_effectively')::numeric;
  v_an   := (c->>'analytical')::numeric;
  v_mdq  := (c->>'makes_decisions_quickly')::numeric;
  v_rc   := (c->>'receives_coaching')::numeric;
  v_pit  := (c->>'positively_influences_team')::numeric;

  v_raw := v_ad*0.20 + v_qtd*0.20 + v_wwcs*0.14 + v_mte*0.14
         + v_an*0.06 + v_mdq*0.10 + v_rc*0.08 + v_pit*0.08;

  IF v_ad <= v_qtd THEN
    v_floor_src := 'attention_to_detail'; v_floor_src_val := v_ad;
  ELSE
    v_floor_src := 'queue_throughput_discipline'; v_floor_src_val := v_qtd;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'retention_support', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'retention_support',
    'contributions', jsonb_build_object(
      'attention_to_detail',           public._cts_role_fit_contrib(v_ad,   0.20, true),
      'queue_throughput_discipline',   public._cts_role_fit_contrib(v_qtd,  0.20, true),
      'works_without_close_supervision',public._cts_role_fit_contrib(v_wwcs, 0.14, false),
      'manages_time_effectively',      public._cts_role_fit_contrib(v_mte,  0.14, false),
      'analytical',                    public._cts_role_fit_contrib(v_an,   0.06, false),
      'makes_decisions_quickly',       public._cts_role_fit_contrib(v_mdq,  0.10, false),
      'receives_coaching',             public._cts_role_fit_contrib(v_rc,   0.08, false),
      'positively_influences_team',    public._cts_role_fit_contrib(v_pit,  0.08, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_retention_support_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$body$;

-- ================================================================
-- STEP 4: Drop the _v2 shells (7 role fns + 2 helpers)
-- ================================================================

DROP FUNCTION public.cts_role_fit_sales_outbound_v2(uuid);
DROP FUNCTION public.cts_role_fit_sales_inbound_v2(uuid);
DROP FUNCTION public.cts_role_fit_sales_in_book_v2(uuid);
DROP FUNCTION public.cts_role_fit_aspirant_v2(uuid);
DROP FUNCTION public.cts_role_fit_retention_reception_v2(uuid);
DROP FUNCTION public.cts_role_fit_retention_escalation_v2(uuid);
DROP FUNCTION public.cts_role_fit_retention_support_v2(uuid);

DROP FUNCTION public._cts_role_fit_apply_gates_v2(uuid, text, numeric, numeric, text, numeric);
DROP FUNCTION public._cts_role_fit_gates_v2(uuid);

COMMIT;
