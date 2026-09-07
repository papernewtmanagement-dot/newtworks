-- Second half of the 2026-09-04 below-band fix (role_fit_gated_v5_10 removed
-- the non-linear penalty). Reasoning ability now reaches the capability score
-- ONLY through its linear weight, which was 1 or 2 against a personality bloc
-- of 18-28. The penalty had been standing in for weight the linear term
-- should have carried, so removing it without this leaves reasoning at
-- roughly 5% of capability.
--
-- Cognitive ability's operational validity for job performance is ~.31
-- (Sackett, Zhang, Berry & Lievens 2022 JAP 107:2040-2068) -- comparable to
-- the best single personality composites, and essentially uncorrelated with
-- them (Ackerman & Heggestad 1997 Psych Bull 121:219-245), which is exactly
-- the condition under which a predictor earns real weight in a composite
-- (Schmidt & Hunter 1998 Psych Bull 124:262-274; Bobko, Roth & Potosky 1999
-- Pers Psych 52:561-589). For insurance sales specifically, cognitive
-- ability and conscientiousness are the two consistent predictors (Vinchur,
-- Schippmann, Switzer & Roth 1998 JAP 83:586-597).
--
-- This table is constrained to weights -1, 0, 1, 2, 3, so parity with the
-- personality bloc cannot be expressed. gma goes to 3, the scale maximum,
-- for every seat. That lifts reasoning from ~4-8% of capability to ~11-14%.
--
-- THE REMAINING DISTORTION IS STRUCTURAL, NOT A WEIGHT VALUE. Capability
-- sums 25 personality facets against 1 cognitive input, so personality
-- out-votes reasoning about 20 to 1 by construction. Unit weighting assumes
-- conceptually distinct predictors (Wainer 1976; Dawes 1979); 25 correlated
-- facets of one construct do not qualify -- their sum is one construct
-- measured 25 ways. The correct fix is construct-level weighting: build the
-- personality composite from its facets, then combine the personality and
-- cognitive blocs at weights reflecting their validities and their near-zero
-- intercorrelation (the Bobko-Roth-Potosky matrix is built for exactly this).
-- That is a rebuild of _newtworks_role_fit_core, tracked as its own open
-- question, not a weight edit.
--
-- Old values for reversal: aspirant 3 (unchanged), sales_outbound 2,
-- sales_inbound 2, sales_in_book 2, retention_escalation 2,
-- retention_reception 1, retention_support 1.
UPDATE public.hiregauge_role_facet_weights
SET weight = 3,
    citation = 'Sackett, Zhang, Berry & Lievens 2022 JAP 107:2040-2068 (operational validity ~.31), uncorrelated with personality (Ackerman & Heggestad 1997) so it earns independent weight in the composite (Schmidt & Hunter 1998; Bobko, Roth & Potosky 1999). Insurance sales: Vinchur, Schippmann, Switzer & Roth 1998 JAP 83:586-597. Raised to the scale maximum 2026-09-04 when the non-linear below-band penalty was removed; the scale caps at 3, so this is a partial correction -- see the construct-level weighting open question.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND input_name = 'gma'
  AND weight < 3;

UPDATE public.hiregauge_scoring_version SET version = version + 1, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
