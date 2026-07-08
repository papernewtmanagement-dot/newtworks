-- Handbook 03 Bonuses & Pay v3: pool-split math wrapped in <details>, Manager Bonus section restored
-- Also corrects open_questions entry that erroneously said "currently stripped in v2"
-- 2026-07-04
--
-- Content payload elided — applied via Supabase MCP apply_migration same session.
-- Diff from v2:
--   * "How Your Slice of the Pool Gets Determined" — narrative up top; 5-factor weighted-hours table + math wrapped in <details><summary>Show me the math</summary> block.
--     Custom Handbook renderer (Handbook.jsx PASSTHROUGH_TAGS + .bcc-handbook-body details/summary CSS) already supports collapsibles.
--   * "Manager Bonus" section restored (UM 0.1% / TM 0.2% / OM 0.3% of agency on-time Scorecard) — placed after "The Bottom Line", before Employment Referral Bonus.
--
-- Also corrects the open_questions entry for Manager Bonus to reflect the restoration.

UPDATE public.handbook
SET content = '<v3 residual-pool content — see handbook table>',
    updated_at = NOW()
WHERE id = '5269ab5a-e575-4287-9ea2-d529b19c90a6';

UPDATE public.persistent_memory
SET content = REPLACE(
      content,
      '(3) if kept, need section in 03 Bonuses & Pay describing it (currently stripped in v2)',
      '(3) restored in v3 handbook with original percentages — evaluate whether to keep as-is or scale under residual pool'
    ),
    updated_at = NOW()
WHERE id = '1581ac95-97e3-40d8-8a24-d1471bc8afc4';
