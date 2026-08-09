-- Convert 41 FIT Conversations support pages from tree-visible 'processes'
-- pages into include-only 'excerpt' rows, and rewrite every reference to them.
--
-- WHY BOTH STEPS: src/lib/markdown.js resolves the two markers from two
-- DIFFERENT row sets. '[Included from: X]' resolves via resolveInclude, which
-- Manual.jsx builds from rows of the CURRENT manual_type. '[Embedded excerpt
-- from: X]' resolves via resolveExcerpt, built from manual_type='excerpt'.
-- Flipping manual_type alone would leave every host page showing a yellow
-- "Missing include" banner. Markers must move in the same transaction.
--
-- Nested case: 'Injuries & Liability Bridge the Gap' references
-- 'Liability Bridge the Gap' and both convert here. mdToHtml runs the include
-- pass BEFORE the excerpt pass, so an include marker sitting inside excerpt
-- content would never expand. Rewriting ALL markers pointing at converted
-- titles (wherever they live, including inside other converted pages) keeps
-- the chain on the excerpt resolver, which recurses to depth 6.
--
-- parent_page_id / tree_root / confluence_page_id are deliberately LEFT INTACT.
-- The processes tree query filters on manual_type, so they are already
-- invisible, and keeping them preserves lineage and makes reversal a single
-- UPDATE back to 'processes'.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_cpids text[] := ARRAY[
    -- FIT Method + every descendant
    '2716631042','2180087810','2619965441','2532802561','2589196289','2514288641','2514616321',
    '2517467137','newtworks-native-life-event-triggers-2026-07-02','878313940','1481932801',
    '2495512592','2543812610',
    -- everything under Simple Auto FIT
    '2589229093','2589294613','2589229085','2588999772','2589294621','2589229077','2589229069','2589294604',
    -- everything under Simple Home FIT
    '2589294646','2224128001','2589425665','2589229117','2589229133','2589229149','2589294662',
    '2589229125','1543995404','2589294638','2589229101','2589294654','2589229109','2589294670',
    -- everything under Simple Liability / Valuables / DI / HI / Retirement Insurance FIT
    '2589294593','2589261838','2589229057','2589261826','2587951221','2589294629'
  ];
  v_title text;
  v_found int;
BEGIN
  SELECT count(*) INTO v_found
  FROM manuals
  WHERE agency_id = v_agency AND confluence_page_id = ANY(v_cpids);

  IF v_found <> array_length(v_cpids, 1) THEN
    RAISE EXCEPTION 'Expected % target rows, found % — aborting',
      array_length(v_cpids, 1), v_found;
  END IF;

  -- Step 1: repoint every reference onto the excerpt resolver.
  FOR v_title IN
    SELECT title FROM manuals
    WHERE agency_id = v_agency AND confluence_page_id = ANY(v_cpids)
  LOOP
    UPDATE manuals
       SET content = replace(
             content,
             '[Included from: ' || v_title || ']',
             '[Embedded excerpt from: ' || v_title || ']'
           ),
           updated_at = now()
     WHERE agency_id = v_agency
       AND content LIKE '%[Included from: ' || v_title || ']%';
  END LOOP;

  -- Step 2: take the pages out of the tree.
  UPDATE manuals
     SET manual_type = 'excerpt',
         updated_at = now()
   WHERE agency_id = v_agency
     AND confluence_page_id = ANY(v_cpids);
END $$;
