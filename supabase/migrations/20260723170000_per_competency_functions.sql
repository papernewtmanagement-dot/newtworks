-- 20260723170000_per_competency_functions.sql
-- One function per unique competency name. Peter directive 2026-07-23.
-- Formulas extracted verbatim from prior per-role competency functions;
-- output byte-identical, internals cleaner, no drift path.

-- ==================== VENDOR REGRESSION-FIT COMPETENCIES ====================

CREATE OR REPLACE FUNCTION public.cts_competency_maintains_high_activity(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (28.073729)
    + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness
    + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion
    + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_handles_rejection(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (21.029494)
    + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness
    + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion
    + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_prospects_in_community(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (10.742427)
    + (-0.004516)*deadline_motivation + (0.222510)*recognition_drive + (0.223384)*assertiveness
    + (0.000353)*independent_spirit + (-0.111467)*analytical + (0.106117)*compassion
    + (0.110739)*self_promotion + (0.114601)*belief_in_others + (0.112072)*optimism
  )::int));
$$;

-- NOTE: dials_cold_calls uses identical coefficients to handles_rejection in current code
-- (suspicious but preserved verbatim; separate function keeps future divergence path open).
CREATE OR REPLACE FUNCTION public.cts_competency_dials_cold_calls(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (21.029494)
    + (0.001498)*deadline_motivation + (0.222634)*recognition_drive + (0.211995)*assertiveness
    + (0.009455)*independent_spirit + (0.106817)*analytical + (-0.111296)*compassion
    + (0.113057)*self_promotion + (-0.099924)*belief_in_others + (0.114323)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_listens_discovers_needs(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (14.551344)
    + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness
    + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion
    + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_presents_solutions(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (0.695513)
    + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness
    + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion
    + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_handles_objections(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (-1.877354)
    + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness
    + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion
    + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_receives_coaching(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (33.550072)
    + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness
    + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion
    + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_positively_influences_team(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT optimism;
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_has_entrepreneurial_spirit(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (0.052334)
    + (0.249428)*deadline_motivation + (0.001218)*recognition_drive + (0.254556)*assertiveness
    + (0.495006)*independent_spirit + (-0.004124)*analytical + (-0.003403)*compassion
    + (0.006260)*self_promotion + (-0.004916)*belief_in_others + (-0.003735)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_balances_logic_and_emotion_when_hiring(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (32.500522)
    + (0.001378)*deadline_motivation + (-0.001370)*recognition_drive + (0.329501)*assertiveness
    + (0.165831)*independent_spirit + (0.162491)*analytical + (-0.163958)*compassion
    + (0.006637)*self_promotion + (-0.168289)*belief_in_others + (0.003683)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_is_fast_start_oriented(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (-0.195183)
    + (0.402392)*deadline_motivation + (0.201362)*recognition_drive + (0.202542)*assertiveness
    + (0.198936)*independent_spirit + (0.000119)*analytical + (-0.003170)*compassion
    + (-0.001383)*self_promotion + (-0.001712)*belief_in_others + (0.000563)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_competes_for_recognition(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT recognition_drive;
$$;

-- ==================== STORY-SPECIFIC COMPETENCIES (hand-spec) ====================

CREATE OR REPLACE FUNCTION public.cts_competency_manages_time_effectively(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (33.197370)
    + (0.167938)*deadline_motivation + (0.170463)*recognition_drive + (0.173435)*assertiveness
    + (0.164096)*independent_spirit + (-0.167532)*analytical + (-0.167799)*compassion
    + (0.001946)*self_promotion + (-0.006913)*belief_in_others + (-0.005379)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_makes_decisions_quickly(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (28.788259)
    + (0.144387)*deadline_motivation + (0.001618)*recognition_drive + (0.140225)*assertiveness
    + (0.137139)*independent_spirit + (-0.143650)*analytical + (-0.146024)*compassion
    + (0.147148)*self_promotion + (-0.001939)*belief_in_others + (0.138712)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_works_without_close_supervision(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (0.014435)
    + (0.334137)*deadline_motivation + (0.000589)*recognition_drive + (0.329735)*assertiveness
    + (0.334420)*independent_spirit + (0.001923)*analytical + (0.000663)*compassion
    + (-0.001501)*self_promotion + (-0.002410)*belief_in_others + (-0.003302)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_analytical(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT analytical;
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_rapid_rapport_warm(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (20.000000)
    + (0.300000)*compassion + (0.200000)*optimism + (0.200000)*belief_in_others
    + (-0.100000)*analytical + (0.050000)*assertiveness
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_cadence_compliance(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (22.000000)
    + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*recognition_drive
    + (0.100000)*belief_in_others + (0.050000)*optimism + (-0.100000)*independent_spirit
    + (-0.050000)*self_promotion
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_routing_judgment(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (22.000000)
    + (0.250000)*analytical + (0.200000)*belief_in_others + (0.150000)*compassion
    + (0.050000)*deadline_motivation + (0.050000)*optimism + (0.050000)*assertiveness
    + (-0.100000)*independent_spirit + (-0.100000)*self_promotion
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_composure_under_load(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (18.000000)
    + (0.250000)*optimism + (0.200000)*compassion + (0.100000)*assertiveness
    + (0.050000)*independent_spirit + (0.050000)*deadline_motivation + (0.050000)*belief_in_others
    + (-0.050000)*analytical
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_pivots_to_customer_need(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (12.000000)
    + (0.250000)*compassion + (0.200000)*analytical + (0.150000)*assertiveness
    + (0.100000)*optimism + (0.100000)*belief_in_others + (0.050000)*recognition_drive
    + (-0.050000)*independent_spirit + (-0.050000)*self_promotion
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_cross_sell_instinct(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (10.000000)
    + (0.200000)*compassion + (0.200000)*analytical + (0.150000)*self_promotion
    + (0.100000)*belief_in_others + (0.100000)*recognition_drive + (0.050000)*deadline_motivation
    + (0.050000)*assertiveness + (-0.050000)*independent_spirit
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_retention_watchfulness(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (20.000000)
    + (0.250000)*compassion + (0.200000)*analytical + (0.100000)*belief_in_others
    + (0.050000)*assertiveness + (0.050000)*deadline_motivation + (-0.050000)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_proactive_touch_discipline(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (20.000000)
    + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*compassion
    + (0.100000)*recognition_drive + (0.050000)*optimism
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_queue_throughput_discipline(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (20.000000)
    + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*independent_spirit
    + (0.100000)*recognition_drive + (0.050000)*optimism + (-0.100000)*self_promotion
  )::int));
$$;

CREATE OR REPLACE FUNCTION public.cts_competency_attention_to_detail(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    (20.000000)
    + (0.300000)*analytical + (0.150000)*deadline_motivation + (0.100000)*compassion
    + (0.100000)*recognition_drive + (0.050000)*independent_spirit + (-0.050000)*optimism
    + (-0.050000)*self_promotion
  )::int));
$$;

-- ==================== ROLE AGGREGATORS (thin, over per-competency functions) ====================

CREATE OR REPLACE FUNCTION public.cts_sales_outbound_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity',      public.cts_competency_maintains_high_activity(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_rejection',            public.cts_competency_handles_rejection(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'prospects_in_community',       public.cts_competency_prospects_in_community(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'dials_cold_calls',             public.cts_competency_dials_cold_calls(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'listens_discovers_needs',      public.cts_competency_listens_discovers_needs(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'presents_solutions',           public.cts_competency_presents_solutions(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_objections',           public.cts_competency_handles_objections(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'receives_coaching',            public.cts_competency_receives_coaching(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'positively_influences_team',   public.cts_competency_positively_influences_team(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism)
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_sales_inbound_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity',      public.cts_competency_maintains_high_activity(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_rejection',            public.cts_competency_handles_rejection(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'listens_discovers_needs',      public.cts_competency_listens_discovers_needs(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'presents_solutions',           public.cts_competency_presents_solutions(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_objections',           public.cts_competency_handles_objections(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'receives_coaching',            public.cts_competency_receives_coaching(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'positively_influences_team',   public.cts_competency_positively_influences_team(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'rapid_rapport_warm',           public.cts_competency_rapid_rapport_warm(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'cadence_compliance',           public.cts_competency_cadence_compliance(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism)
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_sales_in_book_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity',      public.cts_competency_maintains_high_activity(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_rejection',            public.cts_competency_handles_rejection(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'listens_discovers_needs',      public.cts_competency_listens_discovers_needs(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'presents_solutions',           public.cts_competency_presents_solutions(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_objections',           public.cts_competency_handles_objections(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'receives_coaching',            public.cts_competency_receives_coaching(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'positively_influences_team',   public.cts_competency_positively_influences_team(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'cross_sell_instinct',          public.cts_competency_cross_sell_instinct(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'retention_watchfulness',       public.cts_competency_retention_watchfulness(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism)
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_retention_reception_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'listens_discovers_needs',      public.cts_competency_listens_discovers_needs(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'makes_decisions_quickly',      public.cts_competency_makes_decisions_quickly(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'receives_coaching',            public.cts_competency_receives_coaching(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'positively_influences_team',   public.cts_competency_positively_influences_team(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'rapid_rapport_warm',           public.cts_competency_rapid_rapport_warm(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'routing_judgment',             public.cts_competency_routing_judgment(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'composure_under_load',         public.cts_competency_composure_under_load(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'pivots_to_customer_need',      public.cts_competency_pivots_to_customer_need(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism)
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity',      public.cts_competency_maintains_high_activity(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'listens_discovers_needs',      public.cts_competency_listens_discovers_needs(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'presents_solutions',           public.cts_competency_presents_solutions(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_objections',           public.cts_competency_handles_objections(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_rejection',            public.cts_competency_handles_rejection(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'receives_coaching',            public.cts_competency_receives_coaching(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'positively_influences_team',   public.cts_competency_positively_influences_team(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'retention_watchfulness',       public.cts_competency_retention_watchfulness(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'proactive_touch_discipline',   public.cts_competency_proactive_touch_discipline(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'composure_under_load',         public.cts_competency_composure_under_load(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism)
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_retention_support_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'manages_time_effectively',       public.cts_competency_manages_time_effectively(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'makes_decisions_quickly',        public.cts_competency_makes_decisions_quickly(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'works_without_close_supervision',public.cts_competency_works_without_close_supervision(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'analytical',                     public.cts_competency_analytical(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'receives_coaching',              public.cts_competency_receives_coaching(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'positively_influences_team',     public.cts_competency_positively_influences_team(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'queue_throughput_discipline',    public.cts_competency_queue_throughput_discipline(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'attention_to_detail',            public.cts_competency_attention_to_detail(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism)
  );
$$;

CREATE OR REPLACE FUNCTION public.cts_aspirant_competencies(
  deadline_motivation int, recognition_drive int, assertiveness int, independent_spirit int,
  analytical int, compassion int, self_promotion int, belief_in_others int, optimism int
) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object(
    'maintains_high_activity',              public.cts_competency_maintains_high_activity(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_rejection',                    public.cts_competency_handles_rejection(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'prospects_in_community',               public.cts_competency_prospects_in_community(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'dials_cold_calls',                     public.cts_competency_dials_cold_calls(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'listens_discovers_needs',              public.cts_competency_listens_discovers_needs(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'presents_solutions',                   public.cts_competency_presents_solutions(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'handles_objections',                   public.cts_competency_handles_objections(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'receives_coaching',                    public.cts_competency_receives_coaching(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'positively_influences_team',           public.cts_competency_positively_influences_team(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'has_entrepreneurial_spirit',           public.cts_competency_has_entrepreneurial_spirit(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'balances_logic_and_emotion_when_hiring', public.cts_competency_balances_logic_and_emotion_when_hiring(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'is_fast_start_oriented',               public.cts_competency_is_fast_start_oriented(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism),
    'competes_for_recognition',             public.cts_competency_competes_for_recognition(deadline_motivation, recognition_drive, assertiveness, independent_spirit, analytical, compassion, self_promotion, belief_in_others, optimism)
  );
$$;
