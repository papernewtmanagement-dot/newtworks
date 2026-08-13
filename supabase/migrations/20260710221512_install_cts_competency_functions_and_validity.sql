-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-10 22:15:12 UTC (ledger name: install_cts_competency_functions_and_validity) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260710221512.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ===== 4 role competency functions (returning jsonb) =====
-- All formulas fit R² > 0.9996 from 20 Cheetah Compare Report candidates.
-- Trait-copy competencies (analytical=AN trait, positively_influences_team=OP, competes_for_recognition=RD) 
-- reference the trait argument directly rather than computing a redundant formula.

CREATE OR REPLACE FUNCTION public.cts_sales_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'handles_rejection', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'prospects_in_community', GREATEST(0, LEAST(100, ROUND((10.742427) + (-0.004516)*deadline_motivation + (0.222510)*recognition_drive + (0.223384)*assertiveness + (0.000353)*independent_spirit + (-0.111467)*analytical + (0.106117)*compassion + (0.110739)*self_promotion + (0.114601)*belief_in_others + (0.112072)*optimism)::int)),
    'dials_cold_calls', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_service_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'manages_time_effectively', GREATEST(0, LEAST(100, ROUND((33.197370) + (0.167938)*deadline_motivation + (0.170463)*recognition_drive + (0.173435)*assertiveness + (0.164096)*independent_spirit + (-0.167532)*analytical + (-0.167799)*compassion + (0.001946)*self_promotion + (-0.006913)*belief_in_others + (-0.005379)*optimism)::int)),
    'makes_decisions_quickly', GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*deadline_motivation + (0.001618)*recognition_drive + (0.140225)*assertiveness + (0.137139)*independent_spirit + (-0.143650)*analytical + (-0.146024)*compassion + (0.147148)*self_promotion + (-0.001939)*belief_in_others + (0.138712)*optimism)::int)),
    'works_without_close_supervision', GREATEST(0, LEAST(100, ROUND((0.014435) + (0.334137)*deadline_motivation + (0.000589)*recognition_drive + (0.329735)*assertiveness + (0.334420)*independent_spirit + (0.001923)*analytical + (0.000663)*compassion + (-0.001501)*self_promotion + (-0.002410)*belief_in_others + (-0.003302)*optimism)::int)),
    'analytical', analytical,
    'pivots_schedules_appointments', GREATEST(0, LEAST(100, ROUND((-0.246547) + (0.000576)*deadline_motivation + (0.499865)*recognition_drive + (0.495410)*assertiveness + (0.000871)*independent_spirit + (-0.001861)*analytical + (0.003769)*compassion + (-0.002526)*self_promotion + (0.003220)*belief_in_others + (0.000872)*optimism)::int)),
    'builds_relationships', GREATEST(0, LEAST(100, ROUND((16.278094) + (0.003039)*deadline_motivation + (0.166042)*recognition_drive + (0.164833)*assertiveness + (0.001261)*independent_spirit + (-0.157346)*analytical + (0.334947)*compassion + (-0.008260)*self_promotion + (0.166155)*belief_in_others + (-0.001070)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_service_sales_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'manages_time_effectively', GREATEST(0, LEAST(100, ROUND((33.197370) + (0.167938)*deadline_motivation + (0.170463)*recognition_drive + (0.173435)*assertiveness + (0.164096)*independent_spirit + (-0.167532)*analytical + (-0.167799)*compassion + (0.001946)*self_promotion + (-0.006913)*belief_in_others + (-0.005379)*optimism)::int)),
    'makes_decisions_quickly', GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*deadline_motivation + (0.001618)*recognition_drive + (0.140225)*assertiveness + (0.137139)*independent_spirit + (-0.143650)*analytical + (-0.146024)*compassion + (0.147148)*self_promotion + (-0.001939)*belief_in_others + (0.138712)*optimism)::int)),
    'works_without_close_supervision', GREATEST(0, LEAST(100, ROUND((0.014435) + (0.334137)*deadline_motivation + (0.000589)*recognition_drive + (0.329735)*assertiveness + (0.334420)*independent_spirit + (0.001923)*analytical + (0.000663)*compassion + (-0.001501)*self_promotion + (-0.002410)*belief_in_others + (-0.003302)*optimism)::int)),
    'analytical', analytical,
    'builds_relationships', GREATEST(0, LEAST(100, ROUND((16.278094) + (0.003039)*deadline_motivation + (0.166042)*recognition_drive + (0.164833)*assertiveness + (0.001261)*independent_spirit + (-0.157346)*analytical + (0.334947)*compassion + (-0.008260)*self_promotion + (0.166155)*belief_in_others + (-0.001070)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'handles_rejection', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'prospects_in_community', GREATEST(0, LEAST(100, ROUND((10.742427) + (-0.004516)*deadline_motivation + (0.222510)*recognition_drive + (0.223384)*assertiveness + (0.000353)*independent_spirit + (-0.111467)*analytical + (0.106117)*compassion + (0.110739)*self_promotion + (0.114601)*belief_in_others + (0.112072)*optimism)::int)),
    'dials_cold_calls', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int))
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_aspirant_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int,
  independent_spirit int, analytical int, compassion int,
  self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'handles_rejection', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'prospects_in_community', GREATEST(0, LEAST(100, ROUND((10.742427) + (-0.004516)*deadline_motivation + (0.222510)*recognition_drive + (0.223384)*assertiveness + (0.000353)*independent_spirit + (-0.111467)*analytical + (0.106117)*compassion + (0.110739)*self_promotion + (0.114601)*belief_in_others + (0.112072)*optimism)::int)),
    'dials_cold_calls', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'has_entrepreneurial_spirit', GREATEST(0, LEAST(100, ROUND((0.052334) + (0.249428)*deadline_motivation + (0.001218)*recognition_drive + (0.254556)*assertiveness + (0.495006)*independent_spirit + (-0.004124)*analytical + (-0.003403)*compassion + (0.006260)*self_promotion + (-0.004916)*belief_in_others + (-0.003735)*optimism)::int)),
    'balances_logic_and_emotion_when_hiring', GREATEST(0, LEAST(100, ROUND((32.500522) + (0.001378)*deadline_motivation + (-0.001370)*recognition_drive + (0.329501)*assertiveness + (0.165831)*independent_spirit + (0.162491)*analytical + (-0.163958)*compassion + (0.006637)*self_promotion + (-0.168289)*belief_in_others + (0.003683)*optimism)::int)),
    'is_fast_start_oriented', GREATEST(0, LEAST(100, ROUND((-0.195183) + (0.402392)*deadline_motivation + (0.201362)*recognition_drive + (0.202542)*assertiveness + (0.198936)*independent_spirit + (0.000119)*analytical + (-0.003170)*compassion + (-0.001383)*self_promotion + (-0.001712)*belief_in_others + (0.000563)*optimism)::int)),
    'competes_for_recognition', recognition_drive
  );
$$;

COMMENT ON FUNCTION public.cts_sales_competencies IS 'CTS sales role competencies as jsonb. All formulas R²>0.9996 from 20 Cheetah Compare Report candidates. positively_influences_team returns optimism trait directly (identity). dials_cold_calls uses identical formula to handles_rejection.';
COMMENT ON FUNCTION public.cts_service_competencies IS 'CTS service role competencies as jsonb. analytical returns the analytical trait directly (identity). positively_influences_team returns optimism trait directly.';
COMMENT ON FUNCTION public.cts_service_sales_competencies IS 'CTS service+sales role competencies as jsonb (7 service + 7 sales). Trait-alias competencies return trait values directly.';
COMMENT ON FUNCTION public.cts_aspirant_competencies IS 'CTS aspirant (agent) role competencies as jsonb. competes_for_recognition returns recognition_drive trait directly (identity). Others as noted for sales/service.';

-- ===== Profile validity function =====
-- Cheetah reports 2 validity metrics: reliability (high/moderate/low) and response_distortion.
-- In the 20-candidate training sample, distortion is universally "low" so we cannot estimate its numeric effect.
-- Reliability variance is limited (15 high, 4 moderate, 1 low) — coefficient signs inconsistent across roles, likely noise.
-- Rather than embed spurious adjustments in OS formulas, we expose validity as a flag for UI to warn users.
CREATE OR REPLACE FUNCTION public.cts_profile_validity(p_assessment_id uuid)
RETURNS TABLE(validity_status text, reliability text, response_distortion text, warning text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  r text;
  d text;
BEGIN
  SELECT ta.reliability, ta.response_distortion INTO r, d
  FROM public.team_assessments ta
  WHERE ta.id = p_assessment_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assessment % not found', p_assessment_id;
  END IF;
  
  RETURN QUERY SELECT
    CASE 
      WHEN r = 'high' AND d = 'low' THEN 'valid'
      WHEN r IS NULL OR d IS NULL THEN 'unknown'
      ELSE 'questionable'
    END,
    r,
    d,
    CASE
      WHEN r IS NULL AND d IS NULL THEN 'Validity metrics not recorded for this assessment.'
      WHEN r = 'low' THEN 'LOW reliability — profile may be internally inconsistent. Interpret scores with caution.'
      WHEN r = 'moderate' THEN 'MODERATE reliability — profile is somewhat inconsistent. Consider retest.'
      WHEN d != 'low' AND d IS NOT NULL THEN 'ELEVATED response distortion — candidate may have been gaming the assessment. Scores should not be treated as face-valid.'
      ELSE NULL
    END;
END;
$$;
COMMENT ON FUNCTION public.cts_profile_validity IS 'Given an assessment id, returns validity status derived from Cheetah reliability + response_distortion metrics. UI should surface warnings alongside role-fit scores. Metrics themselves are not folded into OS/competency formulas because the training sample lacks variance to identify their effect (20 candidates: 15 high/4 moderate/1 low reliability, 20/20 low distortion).';

-- ===== Drop the 4 competency jsonb columns =====
-- Per directive: all values in team_assessments should be either primary traits or R²>0.999 derivations.
-- Since the derivations are now available at runtime via functions, storing them is redundant.
ALTER TABLE public.team_assessments
  DROP COLUMN IF EXISTS sales_competencies,
  DROP COLUMN IF EXISTS service_competencies,
  DROP COLUMN IF EXISTS service_sales_competencies,
  DROP COLUMN IF EXISTS agent_competencies;
