-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 02:34:47 UTC (ledger name: v2_assessment_gma_and_vocab_trim) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802023447.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- GMA cut from 75 to 16 items (4 per subtest, spanning difficulty range).
-- Deactivate, don't delete — preserves items for future calibration swap-in.
-- ============================================================================

-- Pattern (30 → 4): one item per explicit tier tag
-- Tier 1 (easy — single-rule sequence): item 1
-- Tier 2 (medium — one-rule elimination): item 3
-- Tier 3 (hard — two rules at once): item 6
-- Tier 4 (hardest — three rules at once): item 10
UPDATE hiregauge_instrument_items SET is_active=false
WHERE section='newtworks_v2_cognitive_gma' AND cognitive_domain='gma_pattern'
  AND item_number NOT IN (1, 3, 6, 10);

-- Numerical (15 → 4): span arithmetic → multiplication → alternating → braided
-- 31: fixed-step addition (easy)
-- 34: multiplication by constant (medium)
-- 39: alternating operations (hard)
-- 42: braided two-sequence (hardest)
UPDATE hiregauge_instrument_items SET is_active=false
WHERE section='newtworks_v2_cognitive_gma' AND cognitive_domain='gma_numerical'
  AND item_number NOT IN (31, 34, 39, 42);

-- Deductive (15 → 4): span valid affirmative → invalid particular (four classical syllogism forms)
-- 47: Barbara (All-All-All valid, easy)
-- 46: Celarent (All-No-No valid, medium negation)
-- 50: Darii (Some-All-Some valid particular)
-- 60: undistributed-middle fallacy (invalid, hardest — trap item)
UPDATE hiregauge_instrument_items SET is_active=false
WHERE section='newtworks_v2_cognitive_gma' AND cognitive_domain='gma_deductive'
  AND item_number NOT IN (46, 47, 50, 60);

-- Verbal (15 → 4): span direct synonym → abstract analogy
-- 61: Happy:Joyful :: Sad:___ (direct synonym, common words, easy)
-- 65: Page:Book :: Slice:___ (part-of relationship, medium)
-- 67: Wheel:Car :: Sail:___ (component-purpose, harder)
-- 71: Key:Lock :: Password:___ (abstract analogous function, hardest)
UPDATE hiregauge_instrument_items SET is_active=false
WHERE section='newtworks_v2_cognitive_gma' AND cognitive_domain='gma_verbal'
  AND item_number NOT IN (61, 65, 67, 71);

-- Move surviving GMA items to Stint 1 (per plan: GMA at test start when candidate fresh)
UPDATE hiregauge_instrument_items SET stint=1
WHERE section='newtworks_v2_cognitive_gma' AND is_active=true;

-- ============================================================================
-- Vocab check trim: 20 → 16 (4 Stint 1 foils + 12 Stint 2 real vocab)
-- Deactivate 4 newly-written items; retain all 8 v1-ported + 4 newly-written
-- with the best difficulty spread (2 easy anchor + 2 hard discriminator).
-- ============================================================================
UPDATE hiregauge_instrument_items SET is_active=false
WHERE section='newtworks_v2_personality' AND stint=2 AND hypothesized_trait IS NULL
  AND item_number IN (352, 353, 354, 355);  -- ambiguous, tenacious, arbitrary, cogent

-- ============================================================================
-- SJT move from Stint 2 to Stint 4 (or Stint 3 if adaptive not triggered — that
-- logic lives in the edge fn, not here). SJT items get the higher stint number;
-- edge fn decides whether to serve them at position 3 or 4.
-- ============================================================================
UPDATE hiregauge_instrument_items SET stint=4
WHERE section='newtworks_v2_sjt';
