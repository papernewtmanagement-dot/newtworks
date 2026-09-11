-- Phase 4 forced-choice personality, 16-trait set: 48 four-statement ranking blocks, written INACTIVE.
-- Section: newtworks_v2_personality_fc_quad, items 776-823 (blocks 1-32 all-positive -> 776-807,
-- blocks 33-48 mixed -> 808-823), response_format forced_choice_quad, stint 2.
-- Source of record: persistent_memory spec row de57d141-0906-46c7-b077-b8f6e853a41e
--   ("SPEC - Phase 4 FC: block assembly of record, 48 quads / 16 traits (assembled 2026-09-11)").
--   192 lines, format block|kind|facet|pole|source|desirability|statement, md5 of the
--   bytewise-sorted lines = a62e7187dc9bcdc9fe1003ff09221ac0. Same mechanics as migration
--   20260825181607 fc_quad_blocks_75_inactive: this migration reads the row and refuses to run
--   unless the checksum matches, so nothing is hand-transcribed.
-- The 192 statements are the existing ones from items 701-775 for the 16 kept facets
--   (Peter 2026-09-10: drop sincerity, fairness, greed_avoidance, anxiety, anger, trust,
--   competitiveness, prove_goal_orientation, avoid_goal_orientation). This migration also
--   refuses to run unless every inserted statement matches a live 701-775 statement on
--   source id, text, facet, pole and desirability, each used exactly once, four facets per block.
-- choices shape identical to 701-775: { "options": {A..D -> {text, facet, pole, source,
--   desirability}}, "block": n, "block_kind": AP|MX }. Canonical letters follow spec-row order
--   (positives first in mixed blocks); the endpoint's seededShuffle path reorders per candidate.
-- NOT touched here: items 701-775 stay active, no norm change, no activation. The flip
--   (deactivate 701-775, activate 776-823) is a later migration, after the norm machinery.

DO $$
DECLARE
  v_src  text;
  v_md5  text;
  v_n    int;
  v_bad  int;
BEGIN
  SELECT content INTO v_src FROM public.persistent_memory
  WHERE id = 'de57d141-0906-46c7-b077-b8f6e853a41e';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'assembly spec row de57d141 not found';
  END IF;

  SELECT count(*),
         md5(string_agg(l, E'\n' ORDER BY l COLLATE "C")),
         count(*) FILTER (WHERE length(l) - length(replace(l, '|', '')) <> 6)
    INTO v_n, v_md5, v_bad
  FROM unnest(string_to_array(v_src, E'\n')) AS l
  WHERE l ~ '^[0-9]+\|(AP|MX)\|';

  IF v_n <> 192 OR v_md5 <> 'a62e7187dc9bcdc9fe1003ff09221ac0' OR v_bad <> 0 THEN
    RAISE EXCEPTION 'assembly checksum failed: % lines, md5 %, % malformed', v_n, v_md5, v_bad;
  END IF;

  IF (SELECT count(*) FROM public.hiregauge_instrument_items
      WHERE section = 'newtworks_v2_personality_fc_quad' AND item_number BETWEEN 701 AND 775) <> 75 THEN
    RAISE EXCEPTION 'expected the 75 live blocks 701-775 in place';
  END IF;
  IF EXISTS (SELECT 1 FROM public.hiregauge_instrument_items
             WHERE section = 'newtworks_v2_personality_fc_quad' AND item_number BETWEEN 776 AND 823) THEN
    RAISE EXCEPTION 'items 776-823 already exist; refusing to double-write';
  END IF;

  INSERT INTO public.hiregauge_instrument_items
    (section, item_number, item_text, choices, stint, is_active, response_format,
     is_nonsense, score_excluded, notes)
  SELECT 'newtworks_v2_personality_fc_quad',
         775 + q.block,
         'Rank these from most like you to least like you at work.',
         jsonb_build_object(
           'options', jsonb_object_agg(q.letter,
                        jsonb_build_object('text', q.stmt, 'facet', q.facet, 'pole', q.pole,
                                           'source', q.source, 'desirability', q.desirability)),
           'block', q.block,
           'block_kind', q.kind),
         2, false, 'forced_choice_quad', false, false,
         'Phase 4 FC quad block ' || q.block || ' of 48 (' || q.kind || '), 16-trait set - assembly of record 2026-09-11, '
           || 'spec de57d141-0906-46c7-b077-b8f6e853a41e; inactive pending the flip'
  FROM (
    SELECT p.*, chr(64 + (row_number() OVER (PARTITION BY p.block ORDER BY p.ord))::int) AS letter
    FROM (
      SELECT t.ord,
             split_part(t.l, '|', 1)::int      AS block,
             split_part(t.l, '|', 2)           AS kind,
             split_part(t.l, '|', 3)           AS facet,
             split_part(t.l, '|', 4)           AS pole,
             split_part(t.l, '|', 5)           AS source,
             split_part(t.l, '|', 6)::numeric  AS desirability,
             substring(t.l from '^(?:[^|]*\|){6}(.*)$') AS stmt
      FROM unnest(string_to_array(v_src, E'\n')) WITH ORDINALITY AS t(l, ord)
      WHERE t.l ~ '^[0-9]+\|(AP|MX)\|'
    ) p
  ) q
  GROUP BY q.block, q.kind;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 48 THEN
    RAISE EXCEPTION 'expected 48 block rows, inserted %', v_n;
  END IF;

  -- Every new statement must be a live 701-775 statement, unchanged.
  SELECT count(*) INTO v_bad
  FROM (
    SELECT o.value->>'source' AS source, o.value->>'text' AS txt, o.value->>'facet' AS facet,
           o.value->>'pole' AS pole, (o.value->>'desirability')::numeric AS des
    FROM public.hiregauge_instrument_items i
    CROSS JOIN LATERAL jsonb_each(i.choices->'options') o
    WHERE i.section = 'newtworks_v2_personality_fc_quad' AND i.item_number BETWEEN 776 AND 823
  ) n
  LEFT JOIN (
    SELECT o.value->>'source' AS source, o.value->>'text' AS txt, o.value->>'facet' AS facet,
           o.value->>'pole' AS pole, (o.value->>'desirability')::numeric AS des
    FROM public.hiregauge_instrument_items i
    CROSS JOIN LATERAL jsonb_each(i.choices->'options') o
    WHERE i.section = 'newtworks_v2_personality_fc_quad' AND i.item_number BETWEEN 701 AND 775
  ) o USING (source, txt, facet, pole, des)
  WHERE o.source IS NULL;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION '% new statements do not match a live 701-775 statement', v_bad;
  END IF;

  -- Each statement used exactly once across the 48 blocks.
  SELECT count(*) - count(DISTINCT o.value->>'source') INTO v_bad
  FROM public.hiregauge_instrument_items i
  CROSS JOIN LATERAL jsonb_each(i.choices->'options') o
  WHERE i.section = 'newtworks_v2_personality_fc_quad' AND i.item_number BETWEEN 776 AND 823;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'a statement is used more than once in 776-823';
  END IF;

  -- Four distinct facets in every block.
  SELECT count(*) INTO v_bad
  FROM public.hiregauge_instrument_items i
  WHERE i.section = 'newtworks_v2_personality_fc_quad' AND i.item_number BETWEEN 776 AND 823
    AND (SELECT count(DISTINCT o.value->>'facet') FROM jsonb_each(i.choices->'options') o) <> 4;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION '% blocks repeat a facet', v_bad;
  END IF;
END $$;
