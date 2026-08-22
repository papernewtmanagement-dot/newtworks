WITH recomputed AS (
  SELECT hc.id AS candidate_id, f.facet_score
  FROM public.hiring_candidates hc
  CROSS JOIN LATERAL public.compute_newtworks_v2_facets_as_row(hc.id) f
  WHERE hc.achievement_striving IS NOT NULL
    AND hc.id != '97a56442-0be5-41f4-a2ba-c4b2f01f079a'
    AND f.hypothesized_trait = 'compassion'
)
UPDATE public.hiring_candidates hc
SET compassion = recomputed.facet_score,
    updated_at = now()
FROM recomputed
WHERE hc.id = recomputed.candidate_id;
