-- Mirror function: cts_sales_competencies with per-competency LSS adjustment layer.
-- Existing cts_sales_competencies stays untouched. Reversible via DROP FUNCTION.
-- Peter approved 2026-07-19.

CREATE OR REPLACE FUNCTION public.cts_sales_competencies_lss_adjusted(
  p_dm int, p_rd int, p_as int, p_is int, p_an int,
  p_co int, p_sp int, p_bo int, p_op int,
  p_m_acc int DEFAULT NULL, p_v_acc int DEFAULT NULL, p_ps_acc int DEFAULT NULL,
  p_m_spd int DEFAULT NULL, p_v_spd int DEFAULT NULL, p_ps_spd int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  v_mh  numeric; v_hr  numeric; v_pic numeric; v_dcc numeric;
  v_ldn numeric; v_ps  numeric; v_ho  numeric; v_rc  numeric; v_pit numeric;

  v_acc_flags int; v_spd_flags int;
  v_acc_signal numeric; v_spd_signal numeric;

  v_adj_mh  numeric := 0; v_adj_hr  numeric := 0; v_adj_pic numeric := 0;
  v_adj_dcc numeric := 0; v_adj_ldn numeric := 0; v_adj_ps  numeric := 0;
  v_adj_ho  numeric := 0; v_adj_rc  numeric := 0; v_adj_pit numeric := 0;

  v_has_lss boolean;
BEGIN
  v_mh  := 28.15587 + 0.28528*p_dm + 0.14349*p_rd + 0.13966*p_as + 0.14295*p_is - 0.13707*p_an - 0.13935*p_co - 0.00444*p_sp - 0.00492*p_bo + 0.00257*p_op;
  v_hr  := 21.07777 + 0.00161*p_dm + 0.22300*p_rd + 0.21436*p_as + 0.00858*p_is + 0.10834*p_an - 0.11088*p_co + 0.11018*p_sp - 0.10065*p_bo + 0.11461*p_op;
  v_pic := 10.73328 - 0.00454*p_dm + 0.22247*p_rd + 0.22301*p_as + 0.00049*p_is - 0.11171*p_an + 0.10604*p_co + 0.11120*p_sp + 0.11474*p_bo + 0.11204*p_op;
  v_dcc := v_hr;
  v_ldn := 14.45172 + 0.00127*p_dm + 0.28550*p_rd + 0.28993*p_as - 0.00518*p_is - 0.14835*p_an + 0.13797*p_co + 0.00310*p_sp + 0.14193*p_bo - 0.00292*p_op;
  v_ps  :=  0.81943 - 0.00333*p_dm + 0.40110*p_rd + 0.40626*p_as - 0.00743*p_is + 0.00023*p_an - 0.00278*p_co + 0.19915*p_sp - 0.00325*p_bo - 0.01035*p_op;
  v_ho  := -1.88260 + 0.00300*p_dm + 0.33248*p_rd + 0.32375*p_as + 0.00929*p_is + 0.00383*p_an + 0.00485*p_co + 0.16643*p_sp + 0.00456*p_bo + 0.17461*p_op;
  v_rc  := 33.53723 - 0.00539*p_dm + 0.10973*p_rd + 0.11325*p_as - 0.10978*p_is - 0.11265*p_an + 0.21690*p_co - 0.11289*p_sp + 0.11334*p_bo + 0.11091*p_op;
  v_pit := p_op::numeric;

  v_has_lss := (p_m_acc IS NOT NULL AND p_v_acc IS NOT NULL AND p_ps_acc IS NOT NULL
                AND p_m_spd IS NOT NULL AND p_v_spd IS NOT NULL AND p_ps_spd IS NOT NULL);

  IF v_has_lss THEN
    v_acc_flags :=
      (CASE WHEN p_m_acc  BETWEEN 10 AND 11 THEN 1 ELSE 0 END) +
      (CASE WHEN p_v_acc  BETWEEN 8  AND 10 THEN 1 ELSE 0 END) +
      (CASE WHEN p_ps_acc BETWEEN 7  AND 9  THEN 1 ELSE 0 END);

    v_spd_flags :=
      (CASE WHEN p_m_spd  BETWEEN 32 AND 50 THEN 1 ELSE 0 END) +
      (CASE WHEN p_v_spd  BETWEEN 20 AND 52 THEN 1 ELSE 0 END) +
      (CASE WHEN p_ps_spd BETWEEN 17 AND 77 THEN 1 ELSE 0 END);

    v_acc_signal := (v_acc_flags - 1.5) / 1.5;
    v_spd_signal := (v_spd_flags - 1.5) / 1.5;

    v_adj_ho  := 15.0 * (1.0 * v_acc_signal + 1.0 * v_spd_signal) / 2.0;
    v_adj_ps  := 15.0 * (0.9 * v_acc_signal + 0.5 * v_spd_signal) / 2.0;
    v_adj_ldn := 15.0 * (0.8 * v_acc_signal + 0.0 * v_spd_signal) / 2.0;
    v_adj_rc  := 15.0 * (0.5 * v_acc_signal + 0.0 * v_spd_signal) / 2.0;
    v_adj_pic := 15.0 * (0.3 * v_acc_signal + 0.2 * v_spd_signal) / 2.0;
    v_adj_pit := 15.0 * (0.2 * v_acc_signal + 0.3 * v_spd_signal) / 2.0;
    v_adj_mh  := 15.0 * (0.0 * v_acc_signal + 0.4 * v_spd_signal) / 2.0;
    v_adj_dcc := 15.0 * (0.0 * v_acc_signal + 0.4 * v_spd_signal) / 2.0;
    v_adj_hr  := 15.0 * (0.0 * v_acc_signal + 0.1 * v_spd_signal) / 2.0;
  END IF;

  RETURN jsonb_build_object(
    'maintains_high_activity',    jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_mh)))::int,
      'lss_delta', round(v_adj_mh, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_mh + v_adj_mh)))::int),
    'handles_rejection',          jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_hr)))::int,
      'lss_delta', round(v_adj_hr, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_hr + v_adj_hr)))::int),
    'prospects_in_community',     jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_pic)))::int,
      'lss_delta', round(v_adj_pic, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_pic + v_adj_pic)))::int),
    'dials_cold_calls',           jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_dcc)))::int,
      'lss_delta', round(v_adj_dcc, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_dcc + v_adj_dcc)))::int),
    'listens_discovers_needs',    jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_ldn)))::int,
      'lss_delta', round(v_adj_ldn, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_ldn + v_adj_ldn)))::int),
    'presents_solutions',         jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_ps)))::int,
      'lss_delta', round(v_adj_ps, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_ps + v_adj_ps)))::int),
    'handles_objections',         jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_ho)))::int,
      'lss_delta', round(v_adj_ho, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_ho + v_adj_ho)))::int),
    'receives_coaching',          jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_rc)))::int,
      'lss_delta', round(v_adj_rc, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_rc + v_adj_rc)))::int),
    'positively_influences_team', jsonb_build_object(
      'base',      GREATEST(0, LEAST(100, round(v_pit)))::int,
      'lss_delta', round(v_adj_pit, 2)::numeric,
      'final',     GREATEST(0, LEAST(100, round(v_pit + v_adj_pit)))::int),
    '_meta', jsonb_build_object(
      'has_lss',   v_has_lss,
      'acc_flags', v_acc_flags,
      'spd_flags', v_spd_flags,
      'role',      'sales',
      'model',     'sensitivity_weighted_v1'
    )
  );
END;
$function$;

COMMENT ON FUNCTION public.cts_sales_competencies_lss_adjusted(int,int,int,int,int,int,int,int,int,int,int,int,int,int,int) IS
'Mirror of cts_sales_competencies with per-competency LSS adjustment. Returns jsonb of {base, lss_delta, final} per competency + _meta. Existing cts_sales_competencies remains untouched. Peter approved 2026-07-19.';
