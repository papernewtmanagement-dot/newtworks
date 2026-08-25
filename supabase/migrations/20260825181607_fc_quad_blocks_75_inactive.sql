-- Phase 4 forced-choice personality: 75 four-statement ranking blocks, written INACTIVE.
-- Section: newtworks_v2_personality_fc_quad, items 701-775, response_format forced_choice_quad.
-- Source of record: persistent_memory spec row c310fba8-cf15-4818-817a-d0a56f2f4719
--   ("SPEC — Phase 4 FC: block assembly of record, 75 quads (assembled 2026-08-24)").
--   300 lines, format block|kind|facet|pole|source|desirability|statement, md5 of the
--   bytewise-sorted lines = fef555b37d4a12094d02b1aa9459c3ef. This migration reads that
--   row and refuses to run unless the checksum matches, so nothing is hand-transcribed
--   (the 2026-08-14 pair migration lost 8 rows to transcription; not repeating that).
-- choices shape: { "options": {A,B,C,D -> {text, facet, pole, source, desirability}},
--   "block": n, "block_kind": AP|MX }. The .options key is deliberate: it routes the
--   item through the edge function's seededShuffle / canonicalLetter path, which the
--   live pairs (501-600) bypass -- the slot-order contaminant the spec measured at z=+3.76.
--   Canonical letters follow spec-row order (positives first in mixed blocks).
-- NOT touched here: live items 501-600, the anger/anxiety flip, activation. Both gates closed.

ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY['instructions'::text,'vct'::text,'cognitive'::text,'cts'::text,
    'newtworks_v1_personality'::text,'newtworks_v1_impression_mgmt'::text,'newtworks_v1_vct'::text,
    'newtworks_v2_personality'::text,'newtworks_v2_cognitive_gma'::text,'newtworks_v2_impression_mgmt'::text,
    'newtworks_v2_vct'::text,'newtworks_v2_sjt'::text,'newtworks_v2_screen'::text,
    'newtworks_v2_personality_fc'::text,'newtworks_v2_personality_fc_quad'::text]));

ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_response_format_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_response_format_check
  CHECK (response_format IS NULL OR response_format = ANY (ARRAY['free_text'::text,
    'vocab_familiarity'::text,'forced_choice_pair'::text,'forced_choice_quad'::text]));

DO $$
DECLARE
  v_src  text;
  v_md5  text;
  v_n    int;
  v_bad  int;
BEGIN
  SELECT content INTO v_src FROM public.persistent_memory
  WHERE id = 'c310fba8-cf15-4818-817a-d0a56f2f4719';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'assembly spec row c310fba8 not found';
  END IF;

  SELECT count(*),
         md5(string_agg(l, E'\n' ORDER BY l COLLATE "C")),
         count(*) FILTER (WHERE length(l) - length(replace(l, '|', '')) <> 6)
    INTO v_n, v_md5, v_bad
  FROM unnest(string_to_array(v_src, E'\n')) AS l
  WHERE l ~ '^[0-9]+\|(AP|MX)\|';

  IF v_n <> 300 OR v_md5 <> 'fef555b37d4a12094d02b1aa9459c3ef' OR v_bad <> 0 THEN
    RAISE EXCEPTION 'assembly checksum failed: % lines, md5 %, % malformed', v_n, v_md5, v_bad;
  END IF;

  IF EXISTS (SELECT 1 FROM public.hiregauge_instrument_items
             WHERE section = 'newtworks_v2_personality_fc_quad') THEN
    RAISE EXCEPTION 'newtworks_v2_personality_fc_quad already has rows; refusing to double-write';
  END IF;

  INSERT INTO public.hiregauge_instrument_items
    (section, item_number, item_text, choices, stint, is_active, response_format,
     is_nonsense, score_excluded, notes)
  SELECT 'newtworks_v2_personality_fc_quad',
         700 + q.block,
         'Rank these from most like you to least like you at work.',
         jsonb_build_object(
           'options', jsonb_object_agg(q.letter,
                        jsonb_build_object('text', q.stmt, 'facet', q.facet, 'pole', q.pole,
                                           'source', q.source, 'desirability', q.desirability)),
           'block', q.block,
           'block_kind', q.kind),
         2, false, 'forced_choice_quad', false, false,
         'Phase 4 FC quad block ' || q.block || ' (' || q.kind || ') — assembly of record 2026-08-24, '
           || 'spec c310fba8-cf15-4818-817a-d0a56f2f4719; inactive pending activation gate'
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
  IF v_n <> 75 THEN
    RAISE EXCEPTION 'expected 75 block rows, inserted %', v_n;
  END IF;
END $$;
