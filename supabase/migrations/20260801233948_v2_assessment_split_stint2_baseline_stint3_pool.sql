-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 23:39:48 UTC (ledger name: v2_assessment_split_stint2_baseline_stint3_pool) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801233948.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Implements the ORIGINAL Ass Fix 5 design that the later ingest sessions
-- (Ass Fix 6/7) drifted from without a documented decision to change it:
-- Stint 2 = 5-6 baseline items per facet. Stint 3 = the REMAINING items
-- from that same already-published, already-cited scale -- not new
-- content, just items that were already ingested but wrongly all left in
-- Stint 2. Pure stint reassignment on existing rows.
--
-- Facets with a fixed/short published scale (no surplus items to hold
-- back) are left untouched in Stint 2 with no Stint 3 pool:
-- dispositional_optimism (6, full LOT-R scored set), assured_dominance
-- (4, full IPIP-IPC PA octant), political_skill_networking (6, full PSI
-- Networking Ability subscale). customer_orientation (24 items, double
-- the expected 12 -- likely a duplication from ingest, flagged separately,
-- NOT touched by this migration pending investigation.
--
-- Keeps the 6 lowest item_numbers (source order) per facet as Stint 2
-- baseline; moves the rest to Stint 3.

WITH ranked AS (
  SELECT id, hypothesized_trait,
         row_number() OVER (PARTITION BY hypothesized_trait ORDER BY item_number) AS rn
  FROM public.hiregauge_instrument_items
  WHERE section = 'newtworks_v2_personality'
    AND stint = 2
    AND retest_of_item_number IS NULL
    AND item_number < 300
    AND hypothesized_trait IN (
      'achievement_striving','anger','anxiety','assertiveness','cautiousness',
      'compassion','cooperation','dutifulness','emotional_stability',
      'enterprising','friendliness','self_discipline','self_efficacy','trust'
    )
)
UPDATE public.hiregauge_instrument_items i
SET stint = 3
FROM ranked r
WHERE i.id = r.id AND r.rn > 6;

SELECT hypothesized_trait, stint, count(*) FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v2_personality' AND retest_of_item_number IS NULL AND item_number < 300
GROUP BY hypothesized_trait, stint ORDER BY hypothesized_trait, stint;
