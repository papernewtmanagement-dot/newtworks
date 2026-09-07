-- Closing out the four remaining items from the manual cleanup (Peter: finish them).
--
-- 1. SIX SECTIONS THAT OPENED TO NOTHING.
--    Four of the six were never content pages at all — "*01 Urgent",
--    "*02 Timely", "*03c Retention Assigned Incorrectly" and "*04a Service -
--    To Work" are saved task list views in ECRM. The instruction on BOD Message
--    Process is literally "Work these ECRM Task List Views in order", so the
--    view name IS the instruction. Those four collapsibles are replaced with
--    the view name stated inline, which is everything the missing page would
--    have said. The other two — a service message template and the list of
--    internet lead providers — are genuinely unwritten, so they now read as
--    an explicit to-do instead of a broken page reference.
--
-- 2. EXPOSURE NOTICE PROCESSES moves out of Operations into Retention.
--    Multi-lining cadences, campaign call lists and the refi contact script are
--    proactive customer outreach, not back-office operations. It becomes a
--    fragment on Retention > Outbound Touches like every other touch there.
--
-- 3. FIVE ORPHAN FRAGMENTS get homes. Nothing embedded any of them, so the
--    content was unreachable in the manual:
--      3 Value Statements            -> FIT Conversations (the why-State-Farm pitch)
--      Auto no Home                  -> Retention > Outbound Touches (cross-sell call)
--      Let me think about it         -> Daily Kickoff > Objection Bank (verified: the
--                                       Objection Bank does not cover this one)
--      What Actually Keeps Customers -> Retention (it is the research behind how
--                                       Retention Points are weighted)
--      FIT Method                    -> DELETED. Zero bytes, no host, nothing to place.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_outb text := 'newtworks-native-outbound-touches-2026-09-04';
  v_old text; v_new text; v_n int;
BEGIN
  ------------------------------------------------------------------
  -- 1a. BOD Message Process
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id=v_agency AND confluence_page_id='878084261';
  v_new := replace(v_old,
    E'*(Page not yet in Newtworks: "Timely Issue Service Message")*\n\n\n\n*(Page not yet in Newtworks: "*01 Urgent")*',
    E'Work ECRM task list view `*01 Urgent`.\n\n*The timely issue service message template still needs to be written.*');
  IF v_new = v_old THEN RAISE EXCEPTION 'BOD Timely block not found'; END IF;
  v_old := v_new;

  v_new := replace(v_old,
    E'*(Page not yet in Newtworks: "*02 Timely")*',
    E'Work ECRM task list view `*02 Timely`.');
  IF v_new = v_old THEN RAISE EXCEPTION 'BOD Standard block not found'; END IF;
  UPDATE manuals SET content=v_new, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='878084261';

  ------------------------------------------------------------------
  -- 1b. Task Organization Process
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id=v_agency AND confluence_page_id='878084356';
  v_new := replace(v_old,
    E'<details>\n<summary>Mis-assigned Retention List</summary>\n\n*(Page not yet in Newtworks: "*03c Retention Assigned Incorrectly")*\n\n</details>',
    E'Work ECRM task list view `*03c Retention Assigned Incorrectly`.');
  IF v_new = v_old THEN RAISE EXCEPTION 'Mis-assigned Retention block not found'; END IF;
  v_old := v_new;

  v_new := replace(v_old,
    E'<details>\n<summary>Service to Work List</summary>\n\n*(Page not yet in Newtworks: "*04a Service - To Work")*\n\n</details>',
    E'Then work ECRM task list view `*04a Service - To Work`.');
  IF v_new = v_old THEN RAISE EXCEPTION 'Service to Work block not found'; END IF;
  UPDATE manuals SET content=v_new, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='878084356';

  ------------------------------------------------------------------
  -- 1c. Quote Support Processes
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id=v_agency AND confluence_page_id='878084192';
  v_new := replace(v_old,
    E'*(Page not yet in Newtworks: "Internet Lead Providers (ILPs)")*',
    E'*The list of internet lead providers still needs to be written here.*');
  IF v_new = v_old THEN RAISE EXCEPTION 'ILP placeholder not found'; END IF;
  UPDATE manuals SET content=v_new, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='878084192';

  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND is_active AND content ILIKE '%Page not yet in Newtworks%';
  IF v_n <> 0 THEN RAISE EXCEPTION '% placeholder(s) still left', v_n; END IF;

  ------------------------------------------------------------------
  -- 2. Exposure Notice Processes -> Retention > Outbound Touches
  ------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND manual_type='excerpt' AND is_active
     AND lower(trim(title))='exposure notice processes';
  IF v_n <> 0 THEN RAISE EXCEPTION 'Exposure Notice Processes excerpt already exists'; END IF;

  UPDATE manuals SET manual_type='excerpt', parent_page_id=v_outb, sort_order=NULL, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='982581354';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Exposure Notice Processes not found'; END IF;

  ------------------------------------------------------------------
  -- 3. Orphans get homes.
  ------------------------------------------------------------------
  -- Outbound Touches picks up the cross-sell call and the exposure notices
  UPDATE manuals SET content = content || $c$



<details>
<summary>Multi-lining and exposure notice outreach</summary>

*[Embedded excerpt from: Exposure Notice Processes]*

</details>



<details>
<summary>Call an auto customer who has no home or renters policy</summary>

*[Embedded excerpt from: Auto no Home]*

</details>$c$, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id=v_outb;

  UPDATE manuals SET parent_page_id=v_outb, updated_at=now()
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='Auto no Home';

  -- FIT Conversations picks up the value pitch
  UPDATE manuals SET content = content || $c$

<details>
<summary>Why State Farm — the three value statements</summary>

*[Embedded excerpt from: 3 Value Statements]*

</details>$c$, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='2124251137';

  UPDATE manuals SET parent_page_id='2124251137', updated_at=now()
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='3 Value Statements';

  -- Objection Bank picks up the stall it did not cover
  UPDATE manuals SET content = content || $c$

<details>
<summary><strong>"Let me think about it"</strong></summary>

*[Embedded excerpt from: Let me think about it]*

</details>$c$, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='newtworks-native-objection-bank';

  UPDATE manuals SET parent_page_id='newtworks-native-objection-bank', updated_at=now()
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='Let me think about it';

  -- Retention picks up the research behind the points weighting
  UPDATE manuals SET content = content || $c$

<details>
<summary>Why we weight retention the way we do</summary>

*[Embedded excerpt from: What Actually Keeps Customers]*

</details>$c$, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='1726546221';

  UPDATE manuals SET parent_page_id='1726546221', updated_at=now()
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='What Actually Keeps Customers';

  -- Empty, unreferenced, nothing to place.
  DELETE FROM manuals
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='FIT Method'
     AND coalesce(length(trim(content)),0) = 0;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'FIT Method was not empty as expected (% rows)', v_n; END IF;
END $$;
