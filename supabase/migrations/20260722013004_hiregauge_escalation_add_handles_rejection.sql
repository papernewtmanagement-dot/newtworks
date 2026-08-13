-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-22 01:30:04 UTC (ledger name: hiregauge_escalation_add_handles_rejection) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260722013004.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT jsonb_build_object(
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int)),
    'handles_rejection', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'retention_watchfulness', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*compassion + (0.200000)*analytical + (0.100000)*belief_in_others + (0.050000)*assertiveness + (0.050000)*deadline_motivation + (-0.050000)*optimism)::int)),
    'proactive_touch_discipline', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*compassion + (0.100000)*recognition_drive + (0.050000)*optimism)::int)),
    'composure_under_load', GREATEST(0, LEAST(100, ROUND((18.000000) + (0.250000)*optimism + (0.200000)*compassion + (0.100000)*assertiveness + (0.050000)*independent_spirit + (0.050000)*deadline_motivation + (0.050000)*belief_in_others + (-0.050000)*analytical)::int))
  );
$function$;

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH adj AS (
    SELECT deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      (lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL) AS has_lss,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END)-1.5)/1.5 AS acc_signal,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END)-1.5)/1.5 AS spd_signal,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END))::int AS acc_flags_int,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END))::int AS spd_flags_int,
      public._cts_reliability_confidence(reliability) AS rel_factor,
      public._cts_distortion_severity(response_distortion) AS dist_sev,
      reliability AS rel, response_distortion AS dist,
      (SELECT jsonb_object_agg(competency, jsonb_build_object('a', lss_acc_weight, 's', lss_spd_weight))
       FROM public.hiregauge_competencies) AS w
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'maintains_high_activity', public._cts_lss_apply_v4((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op, (w->'maintains_high_activity'->>'a')::numeric, (w->'maintains_high_activity'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'listens_discovers_needs', public._cts_lss_apply_v4((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op, (w->'listens_discovers_needs'->>'a')::numeric, (w->'listens_discovers_needs'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'presents_solutions', public._cts_lss_apply_v4((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op, (w->'presents_solutions'->>'a')::numeric, (w->'presents_solutions'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'handles_objections', public._cts_lss_apply_v4((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op, (w->'handles_objections'->>'a')::numeric, (w->'handles_objections'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'handles_rejection', public._cts_lss_apply_v4((21.029494) + (0.001498)*dm + (0.222634)*rd + (0.211995)*ass + (0.009455)*is_val + (0.106817)*an + (-0.111296)*com + (0.113057)*sp + (-0.099924)*bo + (0.114323)*op, (w->'handles_rejection'->>'a')::numeric, (w->'handles_rejection'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'receives_coaching', public._cts_lss_apply_v4((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op, (w->'receives_coaching'->>'a')::numeric, (w->'receives_coaching'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'positively_influences_team', public._cts_lss_apply_v4(op::numeric, (w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'retention_watchfulness', public._cts_lss_apply_v4((20.000000) + (0.250000)*com + (0.200000)*an + (0.100000)*bo + (0.050000)*ass + (0.050000)*dm + (-0.050000)*op, (w->'retention_watchfulness'->>'a')::numeric, (w->'retention_watchfulness'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'proactive_touch_discipline', public._cts_lss_apply_v4((20.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*com + (0.100000)*rd + (0.050000)*op, (w->'proactive_touch_discipline'->>'a')::numeric, (w->'proactive_touch_discipline'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'composure_under_load', public._cts_lss_apply_v4((18.000000) + (0.250000)*op + (0.200000)*com + (0.100000)*ass + (0.050000)*is_val + (0.050000)*dm + (0.050000)*bo + (-0.050000)*an, (w->'composure_under_load'->>'a')::numeric, (w->'composure_under_load'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    '_lss_deltas', jsonb_build_object(
      'maintains_high_activity',    public._cts_lss_delta_v4((w->'maintains_high_activity'->>'a')::numeric,    (w->'maintains_high_activity'->>'s')::numeric,    acc_signal, spd_signal, has_lss),
      'listens_discovers_needs',    public._cts_lss_delta_v4((w->'listens_discovers_needs'->>'a')::numeric,    (w->'listens_discovers_needs'->>'s')::numeric,    acc_signal, spd_signal, has_lss),
      'presents_solutions',         public._cts_lss_delta_v4((w->'presents_solutions'->>'a')::numeric,         (w->'presents_solutions'->>'s')::numeric,         acc_signal, spd_signal, has_lss),
      'handles_objections',         public._cts_lss_delta_v4((w->'handles_objections'->>'a')::numeric,         (w->'handles_objections'->>'s')::numeric,         acc_signal, spd_signal, has_lss),
      'handles_rejection',          public._cts_lss_delta_v4((w->'handles_rejection'->>'a')::numeric,          (w->'handles_rejection'->>'s')::numeric,          acc_signal, spd_signal, has_lss),
      'receives_coaching',          public._cts_lss_delta_v4((w->'receives_coaching'->>'a')::numeric,          (w->'receives_coaching'->>'s')::numeric,          acc_signal, spd_signal, has_lss),
      'positively_influences_team', public._cts_lss_delta_v4((w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric, acc_signal, spd_signal, has_lss),
      'retention_watchfulness',     public._cts_lss_delta_v4((w->'retention_watchfulness'->>'a')::numeric,     (w->'retention_watchfulness'->>'s')::numeric,     acc_signal, spd_signal, has_lss),
      'proactive_touch_discipline', public._cts_lss_delta_v4((w->'proactive_touch_discipline'->>'a')::numeric, (w->'proactive_touch_discipline'->>'s')::numeric, acc_signal, spd_signal, has_lss),
      'composure_under_load',       public._cts_lss_delta_v4((w->'composure_under_load'->>'a')::numeric,       (w->'composure_under_load'->>'s')::numeric,       acc_signal, spd_signal, has_lss)
    ),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'retention_escalation', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;
