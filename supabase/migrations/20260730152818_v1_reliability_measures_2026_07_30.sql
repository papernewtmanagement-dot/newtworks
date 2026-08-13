-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 15:28:18 UTC (ledger name: v1_reliability_measures_2026_07_30) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730152818.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Newtworks v1 assessment: per-trait reliability measures.
-- Adds compute_newtworks_v1_reliability and threads outputs into the
-- traits-as-row RPC. Edge fn consumers destructure only the fields they
-- need, so the added column is safe. Frontend never calls the RPC directly.

CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_reliability(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL,
  p_sitting integer DEFAULT NULL
)
RETURNS TABLE(
  trait text,
  n_items integer,
  cronbach_alpha numeric,
  split_half numeric,
  mean_item_total_r numeric
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  r RECORD;
  v_n int;
  v_alpha numeric;
  v_odd_scores numeric[];
  v_even_scores numeric[];
  v_r_half numeric;
  v_split numeric;
  v_it_r_avg numeric;
BEGIN
  FOR r IN
    SELECT
      i.hypothesized_trait AS the_trait,
      array_agg(
        (CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value ELSE r.response_value END)::numeric
        ORDER BY i.item_number, r.created_at
      ) AS adj_arr,
      count(*)::int AS n
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v1_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND r.response_value IS NOT NULL
      AND i.is_active
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR r.sitting = p_sitting)
    GROUP BY i.hypothesized_trait
  LOOP
    v_n := r.n;
    v_alpha := NULL;  -- cross-candidate alpha comes with population fn later

    -- Split-half: odd vs even items, Pearson r, Spearman-Brown corrected.
    IF v_n >= 4 THEN
      SELECT array_agg(x ORDER BY ord) INTO v_odd_scores
      FROM (SELECT x, ord FROM unnest(r.adj_arr) WITH ORDINALITY t(x, ord) WHERE ord % 2 = 1) s;

      SELECT array_agg(x ORDER BY ord) INTO v_even_scores
      FROM (SELECT x, ord FROM unnest(r.adj_arr) WITH ORDINALITY t(x, ord) WHERE ord % 2 = 0) s;

      DECLARE
        m int := LEAST(array_length(v_odd_scores, 1), array_length(v_even_scores, 1));
        mean_o numeric; mean_e numeric;
        sum_cov numeric := 0;
        sum_var_o numeric := 0;
        sum_var_e numeric := 0;
        i int;
      BEGIN
        IF m >= 2 THEN
          SELECT avg(x) INTO mean_o FROM unnest(v_odd_scores[1:m])  AS t(x);
          SELECT avg(x) INTO mean_e FROM unnest(v_even_scores[1:m]) AS t(x);
          FOR i IN 1..m LOOP
            sum_cov   := sum_cov   + (v_odd_scores[i]  - mean_o) * (v_even_scores[i] - mean_e);
            sum_var_o := sum_var_o + power(v_odd_scores[i]  - mean_o, 2);
            sum_var_e := sum_var_e + power(v_even_scores[i] - mean_e, 2);
          END LOOP;
          IF sum_var_o > 0 AND sum_var_e > 0 THEN
            v_r_half := sum_cov / sqrt(sum_var_o * sum_var_e);
            v_split := (2 * v_r_half) / NULLIF(1 + v_r_half, 0);
          ELSE
            v_split := NULL;
          END IF;
        ELSE
          v_split := NULL;
        END IF;
      END;
    ELSE
      v_split := NULL;
    END IF;

    -- Mean item-total correlation
    IF v_n >= 3 THEN
      DECLARE
        i int;
        total numeric;
        item_series numeric[] := ARRAY[]::numeric[];
        rest_series numeric[] := ARRAY[]::numeric[];
        mean_i numeric; mean_rest numeric;
        sum_cov numeric; sum_var_i numeric; sum_var_r numeric;
      BEGIN
        SELECT sum(x) INTO total FROM unnest(r.adj_arr) AS t(x);
        FOR i IN 1..v_n LOOP
          item_series := item_series || r.adj_arr[i];
          rest_series := rest_series || (total - r.adj_arr[i]);
        END LOOP;
        SELECT avg(x) INTO mean_i    FROM unnest(item_series) AS t(x);
        SELECT avg(x) INTO mean_rest FROM unnest(rest_series) AS t(x);
        sum_cov := 0; sum_var_i := 0; sum_var_r := 0;
        FOR i IN 1..v_n LOOP
          sum_cov   := sum_cov   + (item_series[i] - mean_i) * (rest_series[i] - mean_rest);
          sum_var_i := sum_var_i + power(item_series[i] - mean_i, 2);
          sum_var_r := sum_var_r + power(rest_series[i] - mean_rest, 2);
        END LOOP;
        IF sum_var_i > 0 AND sum_var_r > 0 THEN
          v_it_r_avg := sum_cov / sqrt(sum_var_i * sum_var_r);
        ELSE
          v_it_r_avg := NULL;
        END IF;
      END;
    ELSE
      v_it_r_avg := NULL;
    END IF;

    RETURN QUERY SELECT
      r.the_trait,
      v_n,
      CASE WHEN v_alpha IS NULL THEN NULL ELSE round(v_alpha, 2) END,
      CASE WHEN v_split IS NULL THEN NULL ELSE round(v_split, 2) END,
      CASE WHEN v_it_r_avg IS NULL THEN NULL ELSE round(v_it_r_avg, 2) END;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.compute_newtworks_v1_reliability(uuid, integer, integer) IS
  'Per-trait reliability from a single candidate. Returns Spearman-Brown split-half + mean item-total correlation. Cronbach alpha stays NULL — cross-candidate alpha is a separate future function. Reverse-coded items flipped to unified polarity before covariance.';

DROP FUNCTION IF EXISTS public.compute_newtworks_v1_traits_as_row(uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.compute_newtworks_v1_traits_as_row(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL,
  p_sitting integer DEFAULT NULL
)
RETURNS TABLE(
  candidate_id uuid,
  assertiveness integer,
  independent_spirit integer,
  compassion integer,
  belief_in_others integer,
  optimism integer,
  analytical integer,
  deadline_motivation integer,
  self_promotion integer,
  recognition_drive integer,
  overall_score integer,
  n_items_scored integer,
  cognitive_score integer,
  cognitive_n integer,
  impression_mgmt_score integer,
  impression_mgmt_n integer,
  nonsense_inflation integer,
  nonsense_n integer,
  retest_divergence numeric,
  retest_n_pairs integer,
  expansion_triggers jsonb,
  reliability_by_trait jsonb
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  agency_id_val uuid := '126794dd-25ff-47d2-a436-724499733365';
  trait_scores jsonb;
  overall_avg int;
  n_items_total int;
  cog record;
  im record;
  nons record;
  ret record;
  triggers jsonb;
  reliability_json jsonb;
BEGIN
  SELECT COALESCE(jsonb_object_agg(t.trait, t.score_0_100), '{}'::jsonb),
         round(avg(t.score_0_100))::int,
         COALESCE(sum(t.n_items), 0)::int
    INTO trait_scores, overall_avg, n_items_total
    FROM public.compute_newtworks_v1_traits(p_candidate_id, p_stint, p_sitting) t;

  SELECT * INTO cog  FROM public.compute_newtworks_v1_cognitive_score      (p_candidate_id, p_stint, p_sitting);
  SELECT * INTO im   FROM public.compute_newtworks_v1_impression_mgmt_score(p_candidate_id, p_stint, p_sitting);
  SELECT * INTO nons FROM public.compute_newtworks_v1_nonsense_inflation   (p_candidate_id, p_stint, p_sitting);
  SELECT * INTO ret  FROM public.compute_newtworks_v1_retest_divergence    (p_candidate_id, p_sitting);

  triggers := public.compute_newtworks_v1_expansion_triggers(
    agency_id_val,
    trait_scores,
    cog.score_0_100,
    im.score_0_100,
    nons.inflation_count,
    ret.avg_divergence
  );

  SELECT COALESCE(
    jsonb_object_agg(rel.trait, jsonb_build_object(
      'n',            rel.n_items,
      'split_half',   rel.split_half,
      'item_total_r', rel.mean_item_total_r,
      'alpha',        rel.cronbach_alpha
    )),
    '{}'::jsonb)
    INTO reliability_json
    FROM public.compute_newtworks_v1_reliability(p_candidate_id, p_stint, p_sitting) rel;

  RETURN QUERY
  SELECT
    p_candidate_id,
    NULLIF(trait_scores ->> 'assertiveness',       '')::int,
    NULLIF(trait_scores ->> 'independent_spirit',  '')::int,
    NULLIF(trait_scores ->> 'compassion',          '')::int,
    NULLIF(trait_scores ->> 'belief_in_others',    '')::int,
    NULLIF(trait_scores ->> 'optimism',            '')::int,
    NULLIF(trait_scores ->> 'analytical',          '')::int,
    NULLIF(trait_scores ->> 'deadline_motivation', '')::int,
    NULLIF(trait_scores ->> 'self_promotion',      '')::int,
    NULLIF(trait_scores ->> 'recognition_drive',   '')::int,
    overall_avg,
    n_items_total,
    cog.score_0_100,
    cog.n_items,
    im.score_0_100,
    im.n_items,
    nons.inflation_count,
    nons.n_nonsense_items,
    ret.avg_divergence,
    ret.n_pairs,
    triggers,
    reliability_json;
END;
$$;
