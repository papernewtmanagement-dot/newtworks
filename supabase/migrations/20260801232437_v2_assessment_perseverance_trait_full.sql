-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-01 23:24:37 UTC (ledger name: v2_assessment_perseverance_trait_full) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260801232437.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Perseverance trait was entirely missing from the v2 item bank -- zero
-- questions existed despite having its own scored column on
-- hiring_candidates. The column comment cited "IPIP Perseverance facet" --
-- verified 2026-08-01 that no such standalone IPIP scale exists. The
-- correct real source, per IPIP's own official cross-reference table
-- (Perseverance/Industriousness/Persistence -> BFAS: Industriousness), is
-- the IPIP version of the Big Five Aspect Scales (BFAS) Industriousness
-- scale: DeYoung, C.G., Quilty, L.C., & Peterson, J.B. (2007). Between
-- facets and domains: 10 aspects of the Big Five. Journal of Personality
-- and Social Psychology, 93, 880-896. Item wording verbatim from IPIP's
-- official scoring key (ipip.ori.org/BFASKeys.htm), public domain.
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, stint, item_text, scale_max, hypothesized_trait, reverse_coded, is_nonsense, is_active, notes)
VALUES
  ('newtworks_v2_personality', 360, 2, 'Carry out my plans.', 5, 'perseverance', false, false, true,
   'IPIP BFAS Industriousness item 1/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. +keyed. Corrects prior inaccurate "IPIP Perseverance" citation -- no such standalone scale exists; Industriousness is the verified real-world equivalent per IPIP''s own construct cross-reference.'),
  ('newtworks_v2_personality', 361, 2, 'Finish what I start.', 5, 'perseverance', false, false, true,
   'IPIP BFAS Industriousness item 2/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. +keyed.'),
  ('newtworks_v2_personality', 362, 2, 'Get things done quickly.', 5, 'perseverance', false, false, true,
   'IPIP BFAS Industriousness item 3/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. +keyed.'),
  ('newtworks_v2_personality', 363, 2, 'Always know what I am doing.', 5, 'perseverance', false, false, true,
   'IPIP BFAS Industriousness item 4/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. +keyed.'),
  ('newtworks_v2_personality', 364, 2, 'Waste my time.', 5, 'perseverance', true, false, true,
   'IPIP BFAS Industriousness item 5/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. -keyed, reverse-scored.'),
  ('newtworks_v2_personality', 365, 2, 'Find it difficult to get down to work.', 5, 'perseverance', true, false, true,
   'IPIP BFAS Industriousness item 6/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. -keyed, reverse-scored.'),
  ('newtworks_v2_personality', 366, 2, 'Mess things up.', 5, 'perseverance', true, false, true,
   'IPIP BFAS Industriousness item 7/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. -keyed, reverse-scored.'),
  ('newtworks_v2_personality', 367, 2, 'Don''t put my mind on the task at hand.', 5, 'perseverance', true, false, true,
   'IPIP BFAS Industriousness item 8/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. -keyed, reverse-scored.'),
  ('newtworks_v2_personality', 368, 2, 'Postpone decisions.', 5, 'perseverance', true, false, true,
   'IPIP BFAS Industriousness item 9/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. -keyed, reverse-scored.'),
  ('newtworks_v2_personality', 369, 2, 'Am easily distracted.', 5, 'perseverance', true, false, true,
   'IPIP BFAS Industriousness item 10/10. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. ipip.ori.org/BFASKeys.htm, public domain. -keyed, reverse-scored.');

-- Retest item, consistent with Peter's directive that all traits keep a
-- retest question. Reworded near-duplicate of item 361, same construct,
-- matching the existing retest-item convention used across the other 21
-- traits (paraphrase of an existing item, not a separate citation).
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, stint, item_text, scale_max, hypothesized_trait, reverse_coded, is_nonsense, retest_of_item_number, is_active, notes)
VALUES
  ('newtworks_v2_personality', 370, 2, 'Complete tasks I begin.', 5, 'perseverance', false, false, 361, true,
   'Retest pair for perseverance item 361 ("Finish what I start."). Reworded per Peter directive 2026-08-01 (all traits keep a retest question). Same construct, IPIP BFAS Industriousness.');

-- Correct the column comment -- it carried the same inaccurate citation.
COMMENT ON COLUMN public.hiring_candidates.perseverance IS
  'IPIP BFAS Industriousness facet (the verified real-world equivalent of "Perseverance" per IPIP''s own construct cross-reference), 10 items + 1 retest, 0-100. DeYoung, Quilty & Peterson 2007 JPSP 93:880-896. v2 only. Corrected 2026-08-01 -- prior comment cited a non-existent "IPIP Perseverance" scale.';

SELECT count(*) AS perseverance_items FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v2_personality' AND hypothesized_trait = 'perseverance' AND is_active = true;
