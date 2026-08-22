-- Newtworks v1 Personality scoring functions
-- Reads a candidate's responses to newtworks_v1_personality items,
-- applies reverse-coded flip using scale_max, rescales to 0-100.

CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_traits(p_candidate_id uuid)
RETURNS TABLE(
  trait text,
  n_items int,
  raw_avg numeric,
  score_0_100 int
)
LANGUAGE sql
STABLE
AS $$
  WITH scored AS (
    SELECT i.hypothesized_trait AS trait,
           CASE 
             WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value 
             ELSE r.response_value 
           END AS adj,
           i.scale_max
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v1_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND r.response_value IS NOT NULL
  )
  SELECT trait,
         count(*)::int AS n_items,
         round(avg(adj)::numeric, 2) AS raw_avg,
         round(((avg(adj) - 1) / (max(scale_max) - 1) * 100)::numeric)::int AS score_0_100
  FROM scored
  GROUP BY trait
  ORDER BY trait;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_traits IS 'Newtworks v1 personality trait scoring. Reads responses to section=newtworks_v1_personality items, applies reverse-coded flip using each item scale_max, rescales avg to 0-100. Returns one row per trait.';

-- Wrapper that returns 9 traits in a single row matching hiring_candidates column shape
CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_traits_as_row(p_candidate_id uuid)
RETURNS TABLE(
  candidate_id uuid,
  assertiveness int,
  independent_spirit int,
  compassion int,
  belief_in_others int,
  optimism int,
  analytical int,
  deadline_motivation int,
  self_promotion int,
  recognition_drive int,
  overall_score int,
  n_items_scored int
)
LANGUAGE sql
STABLE
AS $$
  WITH t AS (
    SELECT trait, score_0_100, n_items 
    FROM public.compute_newtworks_v1_traits(p_candidate_id)
  )
  SELECT
    p_candidate_id AS candidate_id,
    (SELECT score_0_100 FROM t WHERE trait = 'assertiveness')::int AS assertiveness,
    (SELECT score_0_100 FROM t WHERE trait = 'independent_spirit')::int AS independent_spirit,
    (SELECT score_0_100 FROM t WHERE trait = 'compassion')::int AS compassion,
    (SELECT score_0_100 FROM t WHERE trait = 'belief_in_others')::int AS belief_in_others,
    (SELECT score_0_100 FROM t WHERE trait = 'optimism')::int AS optimism,
    (SELECT score_0_100 FROM t WHERE trait = 'analytical')::int AS analytical,
    (SELECT score_0_100 FROM t WHERE trait = 'deadline_motivation')::int AS deadline_motivation,
    (SELECT score_0_100 FROM t WHERE trait = 'self_promotion')::int AS self_promotion,
    (SELECT score_0_100 FROM t WHERE trait = 'recognition_drive')::int AS recognition_drive,
    (SELECT round(avg(score_0_100))::int FROM t) AS overall_score,
    (SELECT sum(n_items)::int FROM t) AS n_items_scored;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_traits_as_row IS 'Newtworks v1 personality trait scoring wrapper. Same shape as hiring_candidates trait columns. Drop-in compatible with existing HireGauge role_fit functions. Returns one row per candidate.';
