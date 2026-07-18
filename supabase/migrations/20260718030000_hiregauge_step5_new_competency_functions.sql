-- HireGauge Sprint Step 5: 5 new competency functions (v1 hand-spec)
-- Roles: sales_inbound, sales_in_book, retention_reception, retention_escalation, retention_support
-- Retained Suggs competencies reuse existing formulas from cts_sales_outbound_competencies /
-- cts_service_competencies. 10 new competencies use hand-spec formulas from sprint spec.
-- Refine after seat-holder cohort accumulates.

-- SALES - INBOUND
-- Signature: MH, HR, LDN, PS, HO, RC, PIT + rapid_rapport_warm + cadence_compliance
-- (dropped PIC, DCC — no prospecting/cold-calling in inbound seat)
CREATE OR REPLACE FUNCTION public.cts_sales_inbound_competencies(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'handles_rejection', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'rapid_rapport_warm', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.300000)*compassion + (0.200000)*optimism + (0.200000)*belief_in_others + (-0.100000)*analytical + (0.050000)*assertiveness)::int)),
    'cadence_compliance', GREATEST(0, LEAST(100, ROUND((22.000000) + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*recognition_drive + (0.100000)*belief_in_others + (0.050000)*optimism + (-0.100000)*independent_spirit + (-0.050000)*self_promotion)::int))
  );
$$;

-- SALES - IN-BOOK
-- Signature: MH, HR, LDN, PS, HO, RC, PIT + cross_sell_instinct + retention_watchfulness
-- (dropped PIC, DCC — no prospecting/cold-calling on renewal book)
CREATE OR REPLACE FUNCTION public.cts_sales_in_book_competencies(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'handles_rejection', GREATEST(0, LEAST(100, ROUND((21.029494) + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'cross_sell_instinct', GREATEST(0, LEAST(100, ROUND((10.000000) + (0.200000)*compassion + (0.200000)*analytical + (0.150000)*self_promotion + (0.100000)*belief_in_others + (0.100000)*recognition_drive + (0.050000)*deadline_motivation + (0.050000)*assertiveness + (-0.050000)*independent_spirit)::int)),
    'retention_watchfulness', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*compassion + (0.200000)*analytical + (0.100000)*belief_in_others + (0.050000)*assertiveness + (0.050000)*deadline_motivation + (-0.050000)*optimism)::int))
  );
$$;

-- RETENTION - RECEPTION
-- Signature: LDN, MDQ, RC, PIT + rapid_rapport_warm + routing_judgment + composure_under_load + pivots_to_customer_need
CREATE OR REPLACE FUNCTION public.cts_retention_reception_competencies(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'makes_decisions_quickly', GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*deadline_motivation + (0.001618)*recognition_drive + (0.140225)*assertiveness + (0.137139)*independent_spirit + (-0.143650)*analytical + (-0.146024)*compassion + (0.147148)*self_promotion + (-0.001939)*belief_in_others + (0.138712)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'rapid_rapport_warm', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.300000)*compassion + (0.200000)*optimism + (0.200000)*belief_in_others + (-0.100000)*analytical + (0.050000)*assertiveness)::int)),
    'routing_judgment', GREATEST(0, LEAST(100, ROUND((22.000000) + (0.250000)*analytical + (0.200000)*belief_in_others + (0.150000)*compassion + (0.050000)*deadline_motivation + (0.050000)*optimism + (0.050000)*assertiveness + (-0.100000)*independent_spirit + (-0.100000)*self_promotion)::int)),
    'composure_under_load', GREATEST(0, LEAST(100, ROUND((18.000000) + (0.250000)*optimism + (0.200000)*compassion + (0.100000)*assertiveness + (0.050000)*independent_spirit + (0.050000)*deadline_motivation + (0.050000)*belief_in_others + (-0.050000)*analytical)::int)),
    'pivots_to_customer_need', GREATEST(0, LEAST(100, ROUND((12.000000) + (0.250000)*compassion + (0.200000)*analytical + (0.150000)*assertiveness + (0.100000)*optimism + (0.100000)*belief_in_others + (0.050000)*recognition_drive + (-0.050000)*independent_spirit + (-0.050000)*self_promotion)::int))
  );
$$;

-- RETENTION - ESCALATION
-- Signature: MH, LDN, PS, HO, RC, PIT + retention_watchfulness + proactive_touch_discipline
CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'retention_watchfulness', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*compassion + (0.200000)*analytical + (0.100000)*belief_in_others + (0.050000)*assertiveness + (0.050000)*deadline_motivation + (-0.050000)*optimism)::int)),
    'proactive_touch_discipline', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*compassion + (0.100000)*recognition_drive + (0.050000)*optimism + (-0.050000)*independent_spirit + (-0.050000)*self_promotion)::int))
  );
$$;

-- RETENTION - SUPPORT
-- Signature: MTE, MDQ, WWCS, AN, RC, PIT + queue_throughput_discipline + attention_to_detail
CREATE OR REPLACE FUNCTION public.cts_retention_support_competencies(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'manages_time_effectively', GREATEST(0, LEAST(100, ROUND((33.197370) + (0.167938)*deadline_motivation + (0.170463)*recognition_drive + (0.173435)*assertiveness + (0.164096)*independent_spirit + (-0.167532)*analytical + (-0.167799)*compassion + (0.001946)*self_promotion + (-0.006913)*belief_in_others + (-0.005379)*optimism)::int)),
    'makes_decisions_quickly', GREATEST(0, LEAST(100, ROUND((28.788259) + (0.144387)*deadline_motivation + (0.001618)*recognition_drive + (0.140225)*assertiveness + (0.137139)*independent_spirit + (-0.143650)*analytical + (-0.146024)*compassion + (0.147148)*self_promotion + (-0.001939)*belief_in_others + (0.138712)*optimism)::int)),
    'works_without_close_supervision', GREATEST(0, LEAST(100, ROUND((0.014435) + (0.334137)*deadline_motivation + (0.000589)*recognition_drive + (0.329735)*assertiveness + (0.334420)*independent_spirit + (0.001923)*analytical + (0.000663)*compassion + (-0.001501)*self_promotion + (-0.002410)*belief_in_others + (-0.003302)*optimism)::int)),
    'analytical', analytical,
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'queue_throughput_discipline', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*independent_spirit + (0.100000)*recognition_drive + (0.050000)*optimism + (-0.100000)*self_promotion)::int)),
    'attention_to_detail', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.300000)*analytical + (0.150000)*deadline_motivation + (0.100000)*compassion + (0.100000)*recognition_drive + (0.050000)*independent_spirit + (-0.050000)*optimism + (-0.050000)*self_promotion)::int))
  );
$$;

COMMENT ON FUNCTION public.cts_sales_inbound_competencies IS
  'HireGauge Step 5 v1: Sales-Inbound competency vector. MH/HR/LDN/PS/HO/RC/PIT from sales_outbound formulas + rapid_rapport_warm + cadence_compliance (hand-spec).';
COMMENT ON FUNCTION public.cts_sales_in_book_competencies IS
  'HireGauge Step 5 v1: Sales-In-Book competency vector. MH/HR/LDN/PS/HO/RC/PIT from sales_outbound formulas + cross_sell_instinct + retention_watchfulness (hand-spec).';
COMMENT ON FUNCTION public.cts_retention_reception_competencies IS
  'HireGauge Step 5 v1: Retention-Reception competency vector. LDN from sales_outbound + MDQ from service + RC + PIT + rapid_rapport_warm + routing_judgment + composure_under_load + pivots_to_customer_need (hand-spec).';
COMMENT ON FUNCTION public.cts_retention_escalation_competencies IS
  'HireGauge Step 5 v1: Retention-Escalation competency vector. MH/LDN/PS/HO/RC/PIT from sales_outbound + retention_watchfulness + proactive_touch_discipline (hand-spec).';
COMMENT ON FUNCTION public.cts_retention_support_competencies IS
  'HireGauge Step 5 v1: Retention-Support competency vector. MTE/MDQ/WWCS/AN/RC/PIT from service + queue_throughput_discipline + attention_to_detail (hand-spec).';
