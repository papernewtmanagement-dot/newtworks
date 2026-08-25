-- Phase 4 forced-choice personality: SCORING LAYER, PHASE 1 (partially-ipsative normative
-- win-rate scoring over the 450 pairwise comparisons). Spec of record: persistent_memory
-- "SPEC — Phase 4 forced-choice rebuild: 75 quad blocks, full ranking, mixed keying
-- (LOCKED 2026-08-22, AMENDED 2026-08-23)". Items 701-775 (section
-- newtworks_v2_personality_fc_quad, migration fc_quad_blocks_75_inactive) stay INACTIVE.
--
-- Ships, in order:
--   1. compute_newtworks_v2fcq_facets_as_row -- THE one quad scoring function (single-source law)
--   2. 25 PROVISIONAL norm rows 'fcq_<facet>' in hiregauge_facet_norms (new keys; fc_<facet> untouched)
--   3. hiregauge_facet_norm_key -- adds the 'v2fcq' -> 'fcq_<facet>' branch; every other branch unchanged
--   4. hiregauge_candidate_personality_source -- three-way source detection for finalize + display
--   5. hiring_candidates.assessment_source check widened to admit 'v2fcq'
--
-- NOT touched: compute_newtworks_v2fc_facets_as_row (live pair scorer, its anger/anxiety flip
-- stays -- that retirement is a separate Peter gate), hiregauge_candidate_used_fc_personality,
-- existing v2fc candidate scores and fc_<facet> norm rows, item activation (separate gate).

-- 1. ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_newtworks_v2fcq_facets_as_row(p_candidate_id uuid, p_sitting integer DEFAULT 1)
RETURNS TABLE(hypothesized_trait text, facet_score integer, n_items_scored integer)
LANGUAGE sql
STABLE
AS $function$
  -- THE single scoring computation for the Phase 4 forced-choice personality
  -- section (single-source law: no other function may score the quad blocks;
  -- consumers call this). Return shape mirrors compute_newtworks_v2_facets_as_row
  -- and compute_newtworks_v2fc_facets_as_row so finalize can consume any of the
  -- three interchangeably.
  --
  -- RESPONSE CONTRACT (delivery wiring conforms as of v1-assessment v46): one row
  -- per answered block in hiregauge_candidate_responses; response_label is the
  -- block's STORED option letters in rank order, most-like-me first (e.g. "BDAC"),
  -- already translated back from display order by the edge function. Case and
  -- whitespace tolerated here; response_value ignored. A label that is not a clean
  -- permutation of the block's letters is ignored, never partially scored.
  --
  -- SCORING (Phase 1, partially-ipsative normative -- Brown & Maydeu-Olivares 2011
  -- EPM 71:460-502; Schulte, Holling & Burkner 2021 EPM; Hontangas et al. 2015
  -- APM 39:598-612 for RANK on tetrads): a full ranking of 4 yields 6 pairwise
  -- comparisons; each statement wins against every statement ranked below it,
  -- so a statement at rank r (1 = most like me) has wins = 4 - r out of 3
  -- comparisons. Each facet has 12 statements x 3 = 36 comparisons per complete
  -- sitting (vs 8 in the pair section). raw = evidence / comparisons * 100 over
  -- the blocks actually answered (partial sittings scored over what was answered,
  -- same rule as the pair scorer). n_items_scored counts statement appearances
  -- (12 per facet when complete), matching the pair scorer's appearance count.
  --
  -- DIRECTION LIVES ON THE STATEMENT (spec amendment 2026-08-23): every option
  -- carries a pole tag. pole '+' = the statement is keyed to the facet's socially
  -- positive end, pole '-' = its negative end (10 + 2 per facet by design;
  -- migration fc_quad_blocks_75_inactive). A '+' statement contributes its wins;
  -- a '-' statement contributes its losses. There is NO facet-wide 100-minus flip.
  --
  -- CALM-POLE PIN, now expressed per statement: anger and anxiety are STORED with
  -- Likert semantics (high = angry / anxious; the negative anger weight in
  -- hiregauge_role_facet_weights depends on it), but their '+' statements are the
  -- CALM pole by the authoring standard ("I keep working politely with someone who
  -- annoys me"), so for those two facets a '+' statement contributes its LOSSES
  -- and a '-' statement its wins. On the 200 statements reused from the pair
  -- section (all calm-pole, all tagged '+') this reproduces the pair scorer's
  -- 100-minus-win-rate exactly, as the spec requires; unlike the flip, it also
  -- scores the angry-pole statements the pair section never had. Every other
  -- facet's '+' pole is its high end (self_discipline '+' = disciplined).
  --
  -- is_active governs SERVING only; score_excluded governs SCORING only -- same
  -- separation as the other two scorers.
  --
  -- Percentile display and role-fit input resolve against the 'fcq_<facet>' norm
  -- rows via hiregauge_facet_norm_key (source 'v2fcq'). Phase 2 (Thurstonian IRT
  -- at N >= 300) replaces the body of this function and nothing else.
  WITH answered AS (
    SELECT i.id AS item_id,
           i.choices -> 'options' AS options,
           upper(btrim(r.response_label)) AS ranking
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.section = 'newtworks_v2_personality_fc_quad'
      AND i.score_excluded IS NOT TRUE
      AND jsonb_typeof(i.choices -> 'options') = 'object'
      AND r.response_label IS NOT NULL
  ),
  valid AS (
    SELECT a.item_id, a.options, a.ranking,
           (SELECT count(*) FROM jsonb_object_keys(a.options)) AS n_letters
    FROM answered a
    WHERE length(a.ranking) = (SELECT count(*) FROM jsonb_object_keys(a.options))
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_object_keys(a.options) AS k
        WHERE length(a.ranking) - length(replace(a.ranking, k, '')) <> 1
      )
  ),
  statements AS (
    SELECT o.value ->> 'facet' AS facet,
           o.value ->> 'pole'  AS pole,
           (v.n_letters - strpos(v.ranking, o.key))::int AS wins,
           (v.n_letters - 1)::int AS comparisons
    FROM valid v
    CROSS JOIN LATERAL jsonb_each(v.options) AS o(key, value)
  ),
  oriented AS (
    SELECT s.facet,
           s.comparisons,
           CASE WHEN (CASE WHEN s.pole = '+' THEN 1 ELSE -1 END)
                   * (CASE WHEN s.facet IN ('anger', 'anxiety') THEN -1 ELSE 1 END) = 1
                THEN s.wins
                ELSE s.comparisons - s.wins END AS evidence
    FROM statements s
    WHERE s.facet IS NOT NULL AND s.pole IN ('+', '-')
  )
  SELECT o.facet AS hypothesized_trait,
         ROUND(SUM(o.evidence)::numeric / NULLIF(SUM(o.comparisons), 0) * 100.0)::int AS facet_score,
         COUNT(*)::int AS n_items_scored
  FROM oriented o
  GROUP BY o.facet;
$function$;

-- 2. ------------------------------------------------------------------------------
INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes, updated_at, updated_by, items_reworded_after_norm)
SELECT n.agency_id,
       'fcq_' || substr(n.facet, 4),
       50,
       13,
       'newtworks_v2fcq forced-choice quad ranking, 0-100 (evidence/comparisons*100 over 36 comparisons per facet; direction per statement pole tag; anger and anxiety stored high = angry/anxious)',
       'PROVISIONAL seed pending local v2fcq pool norms (norm-referenced interpretation: Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014). Format basis: Brown & Maydeu-Olivares 2011 EPM 71:460-502; Schulte, Holling & Burkner 2021 EPM; Hontangas et al. 2015 APM 39:598-612; Cao & Drasgow 2019 JAP 104:1347-1368.',
       'seeded by migration fc_quad_scoring_phase1_norms_and_source, 2026-08-25',
       'PROVISIONAL seed (mean 50, SD 13) until N>=20 completed v2fcq assessments; then recompute local-pool mean/sd mirroring the gma/sjt local-norm pattern in migration 20260814043100. Mean 50: the 50 all-positive blocks pin the average facet score at 50 by construction; the 25 mixed blocks can lift it, so expect the pooled mean above 50 and replace this. SD 13 (not the pair section''s 18): binomial noise at 36 comparisons is 100*sqrt(.25/36) = 8.3 points; adding a plausible true-score spread of 10 gives ~13 combined. Replace with the observed pooled SD at N>=20.',
       now(),
       'claude_migration',
       false
FROM public.hiregauge_facet_norms n
WHERE n.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND n.facet LIKE 'fc\_%'
ON CONFLICT (agency_id, facet) DO NOTHING;

-- 3. ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_facet_norm_key(p_source text, p_facet text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  -- Single mapping point between a candidate's assessment_source and the norm
  -- row their facet raws are percentiled against (added 2026-08-14, Phase 3
  -- forced-choice scoring). 'v2fc' candidates read the provisional
  -- 'fc_<facet>' rows in hiregauge_facet_norms, because forced-choice win
  -- rates and Likert facet means are different scales with different
  -- reference distributions (Cao & Drasgow 2019; Salgado & Tauriz 2014;
  -- Salgado, Anderson & Tauriz 2015) -- percentiling one against the other's
  -- norms would violate the common-scale rule documented in
  -- _newtworks_role_fit_core. 'v2fcq' candidates (Phase 4 quad ranking blocks,
  -- added 2026-08-25) read the 'fcq_<facet>' rows for the same reason: 36
  -- comparisons per facet with mixed keying is a third scale, and the spec
  -- forbids reusing fc_<facet>. Every other source ('v2', 'v1', NULL) keeps the
  -- facet name unchanged. gma, sjt and gma_speed are cognitive / pool norms
  -- shared across sources and are never prefixed, even if a careless future
  -- call site routes them through here.
  SELECT CASE
    WHEN p_source = 'v2fcq' AND p_facet NOT IN ('gma', 'sjt', 'gma_speed')
      THEN 'fcq_' || p_facet
    WHEN p_source = 'v2fc' AND p_facet NOT IN ('gma', 'sjt', 'gma_speed')
      THEN 'fc_' || p_facet
    ELSE p_facet
  END;
$function$;

-- 4. ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_candidate_personality_source(p_candidate_id uuid, p_sitting integer DEFAULT 1)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
  -- Which stint-2 personality section a candidate actually answered, and so
  -- which scorer and assessment_source apply: 'v2fcq' (Phase 4 quad blocks),
  -- 'v2fc' (Phase 3 pairs) or 'v2' (Likert). Data-driven, never a per-candidate
  -- flag set at invite time -- one assessment is served at any moment and the
  -- stint-2 lock in v1-assessment keeps a mid-sitting candidate on the section
  -- they started. Quad is checked first because it is the newest section.
  -- Supersedes the boolean hiregauge_candidate_used_fc_personality for new
  -- call sites; that function is left as-is for anything still calling it.
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM public.hiregauge_candidate_responses r
      JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
      WHERE r.candidate_id = p_candidate_id AND r.sitting = p_sitting
        AND i.section = 'newtworks_v2_personality_fc_quad')
      THEN 'v2fcq'
    WHEN EXISTS (
      SELECT 1 FROM public.hiregauge_candidate_responses r
      JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
      WHERE r.candidate_id = p_candidate_id AND r.sitting = p_sitting
        AND i.section = 'newtworks_v2_personality_fc')
      THEN 'v2fc'
    ELSE 'v2'
  END;
$function$;

-- 5. ------------------------------------------------------------------------------
ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS hiring_candidates_assessment_source_check;
ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_assessment_source_check
  CHECK (assessment_source = ANY (ARRAY['v1'::text, 'v2'::text, 'cts'::text, 'v2fc'::text, 'v2fcq'::text])
         OR assessment_source IS NULL);
