-- v2 assessment schema, parallel-columns architecture
-- Path A rename doctrine, per operational_rule
-- "Newtworks v1 assessment v2 build — public-domain source catalog + Path A principle"
-- 27 new columns on hiring_candidates. No renames, no drops.
-- v1 columns stay live; v2 flag distinguishes assessment version per row.

-- Assessment version flag
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS v2 boolean NOT NULL DEFAULT false;

-- Cognitive: ICAR-16 (Condon & Revelle 2014)
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS icar_letter_number_series integer
    CHECK (icar_letter_number_series IS NULL OR (icar_letter_number_series >= 0 AND icar_letter_number_series <= 100)),
  ADD COLUMN IF NOT EXISTS icar_matrix_reasoning integer
    CHECK (icar_matrix_reasoning IS NULL OR (icar_matrix_reasoning >= 0 AND icar_matrix_reasoning <= 100)),
  ADD COLUMN IF NOT EXISTS icar_verbal_reasoning integer
    CHECK (icar_verbal_reasoning IS NULL OR (icar_verbal_reasoning >= 0 AND icar_verbal_reasoning <= 100)),
  ADD COLUMN IF NOT EXISTS icar_3d_rotation integer
    CHECK (icar_3d_rotation IS NULL OR (icar_3d_rotation >= 0 AND icar_3d_rotation <= 100)),
  ADD COLUMN IF NOT EXISTS icar_total_score integer
    CHECK (icar_total_score IS NULL OR (icar_total_score >= 0 AND icar_total_score <= 100));

-- Personality: 21 new facets
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS achievement_striving integer
    CHECK (achievement_striving IS NULL OR (achievement_striving >= 0 AND achievement_striving <= 100)),
  ADD COLUMN IF NOT EXISTS self_discipline integer
    CHECK (self_discipline IS NULL OR (self_discipline >= 0 AND self_discipline <= 100)),
  ADD COLUMN IF NOT EXISTS emotional_stability integer
    CHECK (emotional_stability IS NULL OR (emotional_stability >= 0 AND emotional_stability <= 100)),
  ADD COLUMN IF NOT EXISTS perseverance integer
    CHECK (perseverance IS NULL OR (perseverance >= 0 AND perseverance <= 100)),
  ADD COLUMN IF NOT EXISTS dutifulness integer
    CHECK (dutifulness IS NULL OR (dutifulness >= 0 AND dutifulness <= 100)),
  ADD COLUMN IF NOT EXISTS customer_orientation integer
    CHECK (customer_orientation IS NULL OR (customer_orientation >= 0 AND customer_orientation <= 100)),
  ADD COLUMN IF NOT EXISTS self_efficacy integer
    CHECK (self_efficacy IS NULL OR (self_efficacy >= 0 AND self_efficacy <= 100)),
  ADD COLUMN IF NOT EXISTS proactive_personality integer
    CHECK (proactive_personality IS NULL OR (proactive_personality >= 0 AND proactive_personality <= 100)),
  ADD COLUMN IF NOT EXISTS cautiousness integer
    CHECK (cautiousness IS NULL OR (cautiousness >= 0 AND cautiousness <= 100)),
  ADD COLUMN IF NOT EXISTS anxiety integer
    CHECK (anxiety IS NULL OR (anxiety >= 0 AND anxiety <= 100)),
  ADD COLUMN IF NOT EXISTS friendliness integer
    CHECK (friendliness IS NULL OR (friendliness >= 0 AND friendliness <= 100)),
  ADD COLUMN IF NOT EXISTS anger integer
    CHECK (anger IS NULL OR (anger >= 0 AND anger <= 100)),
  ADD COLUMN IF NOT EXISTS cooperation integer
    CHECK (cooperation IS NULL OR (cooperation >= 0 AND cooperation <= 100)),
  ADD COLUMN IF NOT EXISTS trust integer
    CHECK (trust IS NULL OR (trust >= 0 AND trust <= 100)),
  ADD COLUMN IF NOT EXISTS assured_dominance integer
    CHECK (assured_dominance IS NULL OR (assured_dominance >= 0 AND assured_dominance <= 100)),
  ADD COLUMN IF NOT EXISTS dispositional_optimism integer
    CHECK (dispositional_optimism IS NULL OR (dispositional_optimism >= 0 AND dispositional_optimism <= 100)),
  ADD COLUMN IF NOT EXISTS political_skill_networking integer
    CHECK (political_skill_networking IS NULL OR (political_skill_networking >= 0 AND political_skill_networking <= 100)),
  ADD COLUMN IF NOT EXISTS enterprising integer
    CHECK (enterprising IS NULL OR (enterprising >= 0 AND enterprising <= 100)),
  ADD COLUMN IF NOT EXISTS sincerity integer
    CHECK (sincerity IS NULL OR (sincerity >= 0 AND sincerity <= 100)),
  ADD COLUMN IF NOT EXISTS fairness integer
    CHECK (fairness IS NULL OR (fairness >= 0 AND fairness <= 100)),
  ADD COLUMN IF NOT EXISTS greed_avoidance integer
    CHECK (greed_avoidance IS NULL OR (greed_avoidance >= 0 AND greed_avoidance <= 100));

-- Column comments (source instrument documentation for future audit)
COMMENT ON COLUMN public.hiring_candidates.v2 IS 'True when this row was scored by the v2 assessment (23-facet Path A rebuild). False for v1. Retires with v1.';
COMMENT ON COLUMN public.hiring_candidates.icar_letter_number_series IS 'ICAR-16 Letter and Number Series subtest, 4 items, 0-100. Condon & Revelle 2014. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.icar_matrix_reasoning IS 'ICAR-16 Matrix Reasoning subtest, 4 items, 0-100. Condon & Revelle 2014. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.icar_verbal_reasoning IS 'ICAR-16 Verbal Reasoning subtest, 4 items, 0-100. Condon & Revelle 2014. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.icar_3d_rotation IS 'ICAR-16 Three-Dimensional Rotation subtest, 4 items, 0-100. Condon & Revelle 2014. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.icar_total_score IS 'ICAR-16 composite (mean of 4 subtest scores), 0-100. Cognitive floor exit gate uses this.';
COMMENT ON COLUMN public.hiring_candidates.achievement_striving IS 'IPIP Achievement Striving facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.self_discipline IS 'IPIP Self-Discipline facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.emotional_stability IS 'IPIP Neuroticism (reversed), 12 items, 0-100. v2 only. NOTE: existing optimism column holds v1-scored Neuroticism-reversed values under prior label.';
COMMENT ON COLUMN public.hiring_candidates.perseverance IS 'IPIP Perseverance facet, 10 items, 0-100. v2 only. Replaces retracted Grit Scale recommendation.';
COMMENT ON COLUMN public.hiring_candidates.dutifulness IS 'IPIP Dutifulness facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.customer_orientation IS 'Brown, Mowen, Donavan & Licata 2002 Customer Orientation, 12 items (6 Needs-focused + 6 Enjoyment-focused), 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.self_efficacy IS 'Schwarzer & Jerusalem 1995 General Self-Efficacy Scale, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.proactive_personality IS 'Seibert, Kraimer & Crant 2001 Proactive Personality Scale, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.cautiousness IS 'IPIP Cautiousness facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.anxiety IS 'IPIP Anxiety facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.friendliness IS 'IPIP Friendliness facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.anger IS 'IPIP Anger facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.cooperation IS 'IPIP Cooperation facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.trust IS 'IPIP Trust facet, 11 items, 0-100. v2 only. NOTE: existing belief_in_others column holds v1-scored Trust values under prior label.';
COMMENT ON COLUMN public.hiring_candidates.assured_dominance IS 'IPIP Assured Dominance facet, 10 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.dispositional_optimism IS 'Scheier, Carver & Bridges 1994 LOT-R Dispositional Optimism, 6 scored items (4 filler items NOT scored), 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.political_skill_networking IS 'Ferris et al. 2005 Political Skill Inventory Networking Ability subscale, 6 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.enterprising IS 'Holland RIASEC / O*NET Interest Profiler Enterprising, 8 items, 0-100. v2 only.';
COMMENT ON COLUMN public.hiring_candidates.sincerity IS 'IPIP-HEXACO Sincerity facet (Honesty-Humility domain), 8 items, 0-100. Ashton, Lee & Goldberg 2007. v2 only. Integrity floor exit gate uses this.';
COMMENT ON COLUMN public.hiring_candidates.fairness IS 'IPIP-HEXACO Fairness facet (Honesty-Humility domain), 8 items, 0-100. Ashton, Lee & Goldberg 2007. v2 only. Integrity floor exit gate uses this.';
COMMENT ON COLUMN public.hiring_candidates.greed_avoidance IS 'IPIP-HEXACO Greed-Avoidance facet (Honesty-Humility domain), 8 items, 0-100. Ashton, Lee & Goldberg 2007. v2 only. Integrity floor exit gate uses this.';
