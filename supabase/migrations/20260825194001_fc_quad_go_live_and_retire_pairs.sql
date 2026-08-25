-- GO-LIVE FLIP + RETIREMENT (Peter-gated, authorized 2026-08-25: "Switch it on and the
-- old one off ... wipe out the old test scores ... questions used in the old test should
-- be used in the new test or removed"). One transaction, so no candidate can be served
-- both stint-2 forced-choice sections at once (same rule as the 2026-08-14 flip).
--
-- Facts checked live before this ran: all 200 statements of the 100 pairs (501-600) are
-- reused inside the 75 quad blocks (701-775; spec 8 of each facet's 10 positives come
-- from the existing bank, verified by checksum in the assembly of record), so removing
-- the pair rows loses no content. 22 candidates touched the pair section: 18 finalized
-- as assessment_source 'v2fc' (13 assessed, 5 declined, 1 in interview -- the 39-pair
-- truncation case), 4 mid-assessment. Nothing else references the pair section
-- (hiregauge_item_extra_traits 0, hiregauge_expansion_triggers 0).
--
-- What this does:
--   1. activates the 75 quad blocks
--   2. wipes pair-test personality scores on the 18 v2fc candidates (25 facet columns,
--      assessment_source, assessment_completed_at). GMA / SJT / screen results stay --
--      those sections are unchanged and were never part of the pair test.
--   3. hard-deletes the 100 pair items; their 2,093 responses go with them (FK cascade).
--      Any of the 22 who reopen their link are served the 75 blocks for stint 2.
--   4. removes the pair-test machinery: its scorer, the boolean source check, the 25
--      provisional fc_<facet> norm rows, the 'v2fc' branches in the norm-key and source
--      functions, and the 'v2fc' / pair-section / forced_choice_pair check values.
--      The migration ledger keeps the history. Likert (newtworks_v2_personality) and
--      v1/cts material are NOT touched here.
--   The facet-wide anger/anxiety flip is not retired in place: its only host is the
--   pair scorer, which is dropped. Direction lives on the statement in the quad scorer.

-- 1 ---------------------------------------------------------------------------------
UPDATE public.hiregauge_instrument_items
SET is_active = true
WHERE section = 'newtworks_v2_personality_fc_quad';

-- 2 ---------------------------------------------------------------------------------
UPDATE public.hiring_candidates
SET achievement_striving = NULL, competitiveness = NULL, learning_goal_orientation = NULL,
    prove_goal_orientation = NULL, avoid_goal_orientation = NULL, self_discipline = NULL,
    emotional_stability = NULL, assertiveness = NULL, dutifulness = NULL,
    customer_orientation = NULL, self_efficacy = NULL, proactive_personality = NULL,
    cautiousness = NULL, anxiety = NULL, friendliness = NULL, anger = NULL,
    cooperation = NULL, trust = NULL, compassion = NULL, dispositional_optimism = NULL,
    political_skill_networking = NULL, enterprising = NULL, sincerity = NULL,
    fairness = NULL, greed_avoidance = NULL,
    assessment_source = NULL,
    assessment_completed_at = NULL
WHERE assessment_source = 'v2fc';

-- 3 ---------------------------------------------------------------------------------
DELETE FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v2_personality_fc';

-- 4 ---------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.compute_newtworks_v2fc_facets_as_row(uuid, integer);
DROP FUNCTION IF EXISTS public.hiregauge_candidate_used_fc_personality(uuid);

DELETE FROM public.hiregauge_facet_norms
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet LIKE 'fc\_%';

CREATE OR REPLACE FUNCTION public.hiregauge_facet_norm_key(p_source text, p_facet text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $function$
  -- Single mapping point between a candidate's assessment_source and the norm
  -- row their facet raws are percentiled against (added 2026-08-14). 'v2fcq'
  -- candidates (Phase 4 quad ranking blocks, live from 2026-08-25) read the
  -- 'fcq_<facet>' rows in hiregauge_facet_norms, because forced-choice
  -- comparison scores and Likert facet means are different scales with
  -- different reference distributions (Cao & Drasgow 2019; Salgado & Tauriz
  -- 2014; Salgado, Anderson & Tauriz 2015) -- percentiling one against the
  -- other's norms would violate the common-scale rule documented in
  -- _newtworks_role_fit_core. The Phase 3 pair section and its 'v2fc' /
  -- 'fc_<facet>' branch were retired 2026-08-25 (migration
  -- fc_quad_go_live_and_retire_pairs). Every other source ('v2', 'v1', NULL)
  -- keeps the facet name unchanged. gma, sjt and gma_speed are cognitive / pool
  -- norms shared across sources and are never prefixed, even if a careless
  -- future call site routes them through here.
  SELECT CASE
    WHEN p_source = 'v2fcq' AND p_facet NOT IN ('gma', 'sjt', 'gma_speed')
      THEN 'fcq_' || p_facet
    ELSE p_facet
  END;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_candidate_personality_source(p_candidate_id uuid, p_sitting integer DEFAULT 1)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
  -- Which stint-2 personality section a candidate actually answered, and so
  -- which scorer and assessment_source apply: 'v2fcq' (Phase 4 quad blocks) or
  -- 'v2' (Likert). Data-driven, never a per-candidate flag set at invite time.
  -- The 'v2fc' pair branch was retired 2026-08-25 with the pair section.
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM public.hiregauge_candidate_responses r
      JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
      WHERE r.candidate_id = p_candidate_id AND r.sitting = p_sitting
        AND i.section = 'newtworks_v2_personality_fc_quad')
      THEN 'v2fcq'
    ELSE 'v2'
  END;
$function$;

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS hiring_candidates_assessment_source_check;
ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_assessment_source_check
  CHECK (assessment_source = ANY (ARRAY['v1'::text, 'v2'::text, 'cts'::text, 'v2fcq'::text])
         OR assessment_source IS NULL);

ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY['instructions'::text,'vct'::text,'cognitive'::text,'cts'::text,
    'newtworks_v1_personality'::text,'newtworks_v1_impression_mgmt'::text,'newtworks_v1_vct'::text,
    'newtworks_v2_personality'::text,'newtworks_v2_cognitive_gma'::text,'newtworks_v2_impression_mgmt'::text,
    'newtworks_v2_vct'::text,'newtworks_v2_sjt'::text,'newtworks_v2_screen'::text,
    'newtworks_v2_personality_fc_quad'::text]));

ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_response_format_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_response_format_check
  CHECK (response_format IS NULL OR response_format = ANY (ARRAY['free_text'::text,
    'vocab_familiarity'::text, 'forced_choice_quad'::text]));
