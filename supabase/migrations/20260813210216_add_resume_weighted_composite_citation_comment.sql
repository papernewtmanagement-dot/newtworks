-- Resume scoring revamp cleanup: attach research citations to
-- resume_weighted_composite() as a persisted function comment.
-- Comment-only — no change to function logic.
-- Citations pulled verbatim from spec session_note
-- "2026-08-12 — Resume scoring revamp: approved spec (signal-level weights
-- + LE anchors + autonomy imputation)", section 6.

COMMENT ON FUNCTION public.resume_weighted_composite(jsonb) IS
'Signal-direct weighted composite over hiregauge_resume_signal_weights (same pattern as role_fit_v5_0_facet_direct). Constructs (Capability/Character/Commitment) remain display groupings only (simple means for UI); this composite does not read them.

CITATIONS (verified 2026-08-12):
McDaniel, Schmidt & Hunter 1988, Personnel Psychology 41 — T&E behavioral-consistency .45 vs point method .11.
Van Iddekinge, Arnold, Frieder & Roth 2019, Personnel Psychology 72 — prehire experience .06 performance, .00 turnover.
Sackett, Zhang, Berry & Lievens 2022, J Applied Psych 107 — structured interviews .42, empirically keyed biodata .38, GMA .31, conscientiousness .19.
Vinchur, Schippmann, Switzer & Roth 1998, J Applied Psych 83 — sales biodata .52 ratings; achievement .41 objective; GMA .04 objective.
Cole, Feild, Giles & Harris 2009, J Business & Psychology 24 — resume-based personality inference unreliable/invalid.
Rosenbaum 1979, Admin Science Quarterly 24 — early promotion shapes later advancement (mixed replication noted).
Mael 1991, Personnel Psychology 44 — biodata equal-access item principle.';
