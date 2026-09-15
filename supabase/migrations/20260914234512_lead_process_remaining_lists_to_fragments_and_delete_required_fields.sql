-- Peter 2026-09-14:
--  1. Delete the "ALL opportunity required fields" section outright.
--  2. Same fragment treatment for the three remaining lists on the page:
--     the Opportunity Lists 01-14 cadence block, Closed Opps to Reopen, and
--     Do Not Solicit. Each body moves into one shared fragment, the page keeps
--     only the marker, and the matching checklist item points at the same row.
DO $mig$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_page   uuid := 'a8ab7ed7-6ba8-4fea-8aaf-d94334f1f38d';
  c    text;
  blk  text;
  body text;
  s    int;
  e    int;
  v_id uuid;
BEGIN
  SELECT m.content INTO c FROM public.manuals m WHERE m.id = v_page;

  -- 1 ── delete the required-fields section -------------------------------
  s := position(E'<details>\n<summary>ALL opportunity required fields' in c);
  e := position(E'<details>\n<summary>How-To</summary>' in c);
  IF s = 0 OR e = 0 OR e <= s THEN RAISE EXCEPTION 'required fields section not found'; END IF;
  c := left(c, s - 1) || substring(c from e);

  -- 2a ── Opportunity Lists 01-14 (the whole cadence block) ---------------
  s := position('**Day 1:**' in c);
  e := position('**Daily Cleanup:**' in c);
  IF s = 0 OR e = 0 OR e <= s THEN RAISE EXCEPTION 'cadence block not found'; END IF;
  blk  := substring(c from s for e - s);
  body := btrim(blk, E' \n');
  INSERT INTO public.manuals (agency_id, manual_type, title, content, content_format, confluence_page_id, is_active)
  VALUES (v_agency, 'excerpt', 'Opportunity Lists 01-14', body, 'markdown', 'newtworks-native-opportunity-lists-01-14', true)
  RETURNING id INTO v_id;
  c := replace(c, blk, E'*[Embedded excerpt from: Opportunity Lists 01-14]*\n\n');
  UPDATE public.checklist_items SET help_excerpt_id = v_id, updated_at = NOW()
  WHERE agency_id = v_agency AND item_key = 'opp_lists';

  -- 2b ── Closed Opps to Reopen -------------------------------------------
  s := position('<summary>#Closed Opps to Reopen</summary>' in c) + length('<summary>#Closed Opps to Reopen</summary>');
  e := position('This one is in the old Opportunities:' in c);
  IF s = 0 OR e = 0 OR e <= s THEN RAISE EXCEPTION 'closed opps section not found'; END IF;
  blk  := substring(c from s for e - s);
  body := btrim(regexp_replace(blk, E'\\s*</details>\\s*$', ''), E' \n');
  INSERT INTO public.manuals (agency_id, manual_type, title, content, content_format, confluence_page_id, is_active)
  VALUES (v_agency, 'excerpt', 'Closed Opps to Reopen', body, 'markdown', 'newtworks-native-closed-opps-to-reopen', true);
  c := replace(c, blk, E'\n\n*[Embedded excerpt from: Closed Opps to Reopen]*\n\n</details>\n\n\n\n');

  -- 2c ── Do Not Solicit ---------------------------------------------------
  s := position('<summary>#Do Not Solicit</summary>' in c) + length('<summary>#Do Not Solicit</summary>');
  IF s = 0 THEN RAISE EXCEPTION 'do not solicit section not found'; END IF;
  blk  := substring(c from s);
  body := btrim(regexp_replace(blk, E'\\s*</details>\\s*$', ''), E' \n');
  INSERT INTO public.manuals (agency_id, manual_type, title, content, content_format, confluence_page_id, is_active)
  VALUES (v_agency, 'excerpt', 'Do Not Solicit', body, 'markdown', 'newtworks-native-do-not-solicit', true)
  RETURNING id INTO v_id;
  c := replace(c, blk, E'\n\n*[Embedded excerpt from: Do Not Solicit]*\n\n</details>\n');
  UPDATE public.checklist_items SET help_excerpt_id = v_id, updated_at = NOW()
  WHERE agency_id = v_agency AND item_key = 'dnc';

  UPDATE public.manuals
  SET content = c, version = COALESCE(version, 0) + 1, updated_at = NOW()
  WHERE id = v_page;
END
$mig$;