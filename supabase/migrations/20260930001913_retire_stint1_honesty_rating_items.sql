-- Peter 2026-09-30: cut the 16 honesty rating questions from Section 1.
-- They fed only gate_b_integrity in hiregauge_v2_stint1_exit_gate (floor 30),
-- which never fired: 62 candidates since 2026-08-25 ranged 42 to 92. They were
-- never a role-fit input. The 4 impression-management items (301-304) and the
-- 8 vocabulary items stay. Serving reads is_active, so nothing else changes;
-- the gate skips Gate B when no honesty facets are scored (v_integrity_n = 3
-- test). Candidates mid-Section-1 finish on the remaining active items.
SET LOCAL hiregauge.allow_item_purge = 'on';
UPDATE public.hiregauge_instrument_items
   SET is_active = false
 WHERE section = 'newtworks_v2_personality'
   AND stint = 1
   AND is_active = true
   AND response_format IS NULL
   AND hypothesized_trait IN ('sincerity','fairness','greed_avoidance');
