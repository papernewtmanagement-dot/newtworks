-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 15:28:51 UTC (ledger name: v1_reliability_fix_var_shadowing_2026_07_30) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730152851.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Fix: variable `r` collided with table alias `r` for hiregauge_candidate_responses
-- inside the FOR loop query. Rename loop var to `trait_row` so the CASE expression
-- unambiguously references the response row.
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
  trait_row RECORD;
  v_n int;
  v_alpha numeric;
  v_odd_scores numeric[];
  v_even_scores numeric[];
  v_r_half numeric;
  v_split numeric;
  v_it_r_avg numeric;
BEGIN
  FOR trait_row IN
    SELECT
      i.hypothesized_trait AS the_trait,
      array_agg(
        (CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - resp.response_value ELSE resp.response_value END)::numeric
        ORDER BY i.item_number, resp.created_at
      ) AS adj_arr,
      count(*)::int AS n
    FROM public.hiregauge_candidate_responses resp
    JOIN public.hiregauge_instrument_items i ON i.id = resp.item_id
    WHERE resp.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v1_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND resp.response_value IS NOT NULL
      AND i.is_active
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND (p_sitting IS NULL OR resp.sitting = p_sitting)
    GROUP BY i.hypothesized_trait
  LOOP
    v_n := trait_row.n;
    v_alpha := NULL;

    IF v_n >= 4 THEN
      SELECT array_agg(x ORDER BY ord) INTO v_odd_scores
      FROM (SELECT x, ord FROM unnest(trait_row.adj_arr) WITH ORDINALITY t(x, ord) WHERE ord % 2 = 1) s;

      SELECT array_agg(x ORDER BY ord) INTO v_even_scores
      FROM (SELECT x, ord FROM unnest(trait_row.adj_arr) WITH ORDINALITY t(x, ord) WHERE ord % 2 = 0) s;

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

    IF v_n >= 3 THEN
      DECLARE
        i int;
        total numeric;
        item_series numeric[] := ARRAY[]::numeric[];
        rest_series numeric[] := ARRAY[]::numeric[];
        mean_i numeric; mean_rest numeric;
        sum_cov numeric; sum_var_i numeric; sum_var_r numeric;
      BEGIN
        SELECT sum(x) INTO total FROM unnest(trait_row.adj_arr) AS t(x);
        FOR i IN 1..v_n LOOP
          item_series := item_series || trait_row.adj_arr[i];
          rest_series := rest_series || (total - trait_row.adj_arr[i]);
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
      trait_row.the_trait,
      v_n,
      CASE WHEN v_alpha IS NULL THEN NULL ELSE round(v_alpha, 2) END,
      CASE WHEN v_split IS NULL THEN NULL ELSE round(v_split, 2) END,
      CASE WHEN v_it_r_avg IS NULL THEN NULL ELSE round(v_it_r_avg, 2) END;
  END LOOP;
END;
$$;
