-- Operations Processes restructure (Peter, 2026-09-04).
--
-- Audited all 25 pages. The section was a bucket: its own body said "where all
-- background processes reside", which was the only thing tying together a
-- monthly rotation, four daily queues, four office chores, three disaster pages
-- and six pure reference documents. Same treatment the Retention section got.
--
--   * Four shell pages that only listed their children are DELETED
--     (Organization, Service Handling, Claims Processes; the Operations
--     Processes root body is replaced with a real intro).
--   * Three new checklists group the work the way the day runs: Daily Queues,
--     Office Upkeep, Disaster Response.
--   * Automated Task Closure in ECRM moves here from Retention, and the five
--     BOD task reference tables it was carrying (118k characters — Auto Tasks
--     alone is 78k) move to BOD Message Process, where the glossary is actually
--     used. The page keeps its own subject: which tasks ECRM can auto-close,
--     now grouped per line of business instead of one flat wall.
--   * Reference-only pages become fragments embedded where they are used:
--     P&C Underwriting Timing and When to Delete a Lead -> Quote Support;
--     When to Delete a Lead also -> Background Tasks; Task Subject Situational
--     Guidance -> Task Organization Process; Referrals -> Inbound Calls (that
--     is where a customer asks for an appraiser or an estate attorney).
--   * The dead anchor on "Expecting catastrophic claims event" is fixed —
--     #Initial-Loss-Reporting-Process never existed as an anchor and that
--     content now lives inside the Inbound Calls fragment.
--
-- NOT touched, deliberately: the two ADM-lead-conversion write-ups (Background
-- Tasks week 3 vs Quote Support) genuinely disagree on steps, as do the two
-- do-not-contact cleanups. Those are Peter's process, not a formatting problem;
-- merging them without a ruling is the mistake made with the late-pay tables
-- earlier today. Six placeholder sections stay placeholders — that content was
-- never written anywhere and cannot be invented.

DO $$
DECLARE
  v_agency  uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_ops     text := '315523073';
  v_atc     text := '2540109825';
  v_bod     text := '878084261';
  v_dq      text := 'newtworks-native-daily-queues-2026-09-04';
  v_up      text := 'newtworks-native-office-upkeep-2026-09-04';
  v_dr      text := 'newtworks-native-disaster-response-2026-09-04';
  v_shells  text[] := ARRAY['866844722','866811973','870350997'];
  v_frag    text[] := ARRAY[
    '878084261','878084356','864190563',                        -- daily queues
    '878575765','878346444','878575747','878313536',            -- office upkeep
    '1587806454','1478524929','870318291',                      -- disaster response
    '1567719425','1689944066','878576139','1505591297'          -- reference
  ];
  v_old text; v_new text; v_n int; v_title text;
  v_auto text; v_bill text; v_fire text; v_health text; v_life text; v_misc text;
BEGIN
  ------------------------------------------------------------------
  -- 0. Guards
  ------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND manual_type='processes' AND is_active
     AND confluence_page_id = ANY(v_frag);
  IF v_n <> array_length(v_frag,1) THEN
    RAISE EXCEPTION 'Expected % fragment targets, found %', array_length(v_frag,1), v_n;
  END IF;

  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND manual_type='processes' AND is_active
     AND confluence_page_id = ANY(v_shells);
  IF v_n <> 3 THEN RAISE EXCEPTION 'Expected 3 shell pages, found %', v_n; END IF;

  -- No excerpt may already own one of these titles.
  SELECT count(*) INTO v_n FROM manuals e
   WHERE e.agency_id=v_agency AND e.manual_type='excerpt' AND e.is_active
     AND lower(trim(e.title)) IN (
       SELECT lower(trim(title)) FROM manuals
        WHERE agency_id=v_agency AND confluence_page_id = ANY(v_frag));
  IF v_n <> 0 THEN RAISE EXCEPTION 'Excerpt title collision: % row(s)', v_n; END IF;

  -- Nothing may reference a shell by marker.
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND is_active
     AND (content ILIKE '%from: Organization]%' OR content ILIKE '%from: Service Handling]%'
       OR content ILIKE '%from: Claims Processes]%');
  IF v_n <> 0 THEN RAISE EXCEPTION 'A shell is referenced by marker (% rows)', v_n; END IF;

  ------------------------------------------------------------------
  -- 1. Pull the six line-of-business blocks out of Automated Task Closure
  --    before rewriting it.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id=v_agency AND confluence_page_id=v_atc;
  v_auto   := substring(v_old from '\*\*Auto\*\*\n\n(.*?)\n\n\*\*Billing\*\*');
  v_bill   := substring(v_old from '\*\*Billing\*\*\n\n(.*?)\n\n\*\*Fire\*\*');
  v_fire   := substring(v_old from '\*\*Fire\*\*\n\n(.*?)\n\n\*\*Health\*\*');
  v_health := substring(v_old from '\*\*Health\*\*\n\n(.*?)\n\n\*\*Life\*\*');
  v_life   := substring(v_old from '\*\*Life\*\*\n\n(.*?)\n\n\*\*Miscellaneous\*\*');
  v_misc   := substring(v_old from '\*\*Miscellaneous\*\*\n\n(.*?)\n\n<details>');
  IF v_auto IS NULL OR v_bill IS NULL OR v_fire IS NULL
     OR v_health IS NULL OR v_life IS NULL OR v_misc IS NULL THEN
    RAISE EXCEPTION 'Auto-close list blocks not found on Automated Task Closure';
  END IF;

  ------------------------------------------------------------------
  -- 2. Three new checklists.
  ------------------------------------------------------------------
  INSERT INTO manuals (agency_id, manual_type, title, content, content_format, confluence_page_id,
                       parent_page_id, sort_order, icon, divider_after, version, is_active,
                       fetched_at, created_at, updated_at)
  VALUES
  (v_agency,'processes','Daily Queues', $c$
**Checklist**

<details>
<summary>Work the BOD message queues</summary>

*[Embedded excerpt from: BOD Message Process]*

</details>



<details>
<summary>Organize and re-assign tasks</summary>

*[Embedded excerpt from: Task Organization Process]*

</details>



<details>
<summary>Assign unassigned cases</summary>

*[Embedded excerpt from: Case Organization Process]*

</details>$c$,'markdown',v_dq,v_ops,10,'📋',false,1,true,now(),now(),now()),

  (v_agency,'processes','Office Upkeep', $c$
**Checklist**

<details>
<summary>Clean the office</summary>

*[Embedded excerpt from: Office Cleaning Process]*

</details>



<details>
<summary>Check supplies and restock</summary>

*[Embedded excerpt from: Supply-Stocking Process]*

</details>



<details>
<summary>Make welcome binders and folders</summary>

*[Embedded excerpt from: Binder/Folder Production Process]*

</details>



<details>
<summary>Printers, scanning, and mail</summary>

*[Embedded excerpt from: Physical Systems Process]*

</details>$c$,'markdown',v_up,v_ops,40,'🧹',false,1,true,now(),now(),now()),

  (v_agency,'processes','Disaster Response', $c$
**Before an event**

<details>
<summary>Prepare the office, phones, and equipment</summary>

*[Embedded excerpt from: Emergency Event]*

</details>



<details>
<summary>Expecting a catastrophic claims event</summary>

*[Embedded excerpt from: Expecting catastrophic claims event]*

</details>

**During and after**

<details>
<summary>Catastrophe claims contacts and resources</summary>

*[Embedded excerpt from: Catastrophe Handling]*

</details>$c$,'markdown',v_dr,v_ops,60,'🌪️',false,1,true,now(),now(),now());

  ------------------------------------------------------------------
  -- 3. Automated Task Closure: move here, keep only its own subject,
  --    group the auto-close list per line of business.
  ------------------------------------------------------------------
  UPDATE manuals
     SET parent_page_id = v_ops, sort_order = 50, updated_at = now(),
         content =
           E'These are the tasks that are available to automatically close using task automation in ECRM.\n\n'
        || E'<details>\n<summary>Auto</summary>\n\n'          || v_auto   || E'\n\n</details>\n\n'
        || E'<details>\n<summary>Billing</summary>\n\n'       || v_bill   || E'\n\n</details>\n\n'
        || E'<details>\n<summary>Fire</summary>\n\n'          || v_fire   || E'\n\n</details>\n\n'
        || E'<details>\n<summary>Health</summary>\n\n'        || v_health || E'\n\n</details>\n\n'
        || E'<details>\n<summary>Life</summary>\n\n'          || v_life   || E'\n\n</details>\n\n'
        || E'<details>\n<summary>Miscellaneous</summary>\n\n' || v_misc   || E'\n\n</details>'
   WHERE agency_id=v_agency AND confluence_page_id=v_atc;

  ------------------------------------------------------------------
  -- 4. The BOD task glossary lands where BOD messages are worked.
  ------------------------------------------------------------------
  UPDATE manuals
     SET content = content || $c$

**What each BOD task means**

<details>
<summary>Auto</summary>

*[Embedded excerpt from: Auto Tasks]*

</details>

<details>
<summary>Billing</summary>

*[Embedded excerpt from: Billing Tasks]*

</details>

<details>
<summary>Fire</summary>

*[Embedded excerpt from: Fire Tasks]*

</details>

<details>
<summary>Health</summary>

*[Embedded excerpt from: Health Tasks]*

</details>

<details>
<summary>Life</summary>

*[Embedded excerpt from: Life Tasks]*

</details>$c$, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id=v_bod;

  ------------------------------------------------------------------
  -- 5. Dead anchor.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id=v_agency AND confluence_page_id='870318291';
  v_new := replace(v_old,
    '- Review our [initial loss reporting process](#Initial-Loss-Reporting-Process).',
    '- Review the initial loss reporting steps in Retention > Inbound.');
  IF v_new = v_old THEN RAISE EXCEPTION 'initial loss reporting anchor not found'; END IF;
  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id='870318291';

  ------------------------------------------------------------------
  -- 6. Reference fragments get embedded where they are used.
  ------------------------------------------------------------------
  -- Quote Support Processes: underwriting timing + the delete rules it ends on
  UPDATE manuals SET content = content || $c$

<details>
<summary>How long underwriting has on a new policy</summary>

*[Embedded excerpt from: P&C Underwriting Timing]*

</details>

<details>
<summary>When to delete a lead</summary>

*[Embedded excerpt from: When to Delete a Lead]*

</details>$c$, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id='878084192';

  -- Background Tasks: week 2 ends on removing people from the book
  UPDATE manuals SET content = content || $c$

<details>
<summary>When to delete a lead</summary>

*[Embedded excerpt from: When to Delete a Lead]*

</details>$c$, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id='812318730';

  -- Task Organization Process: the naming rules were buried a level below it
  UPDATE manuals SET content = content || $c$

<details>
<summary>How to word a task subject</summary>

*[Embedded excerpt from: Task Subject Situational Guidance]*

</details>$c$, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id='878084356';

  -- Referrals: reached for on an inbound call
  UPDATE manuals SET content = content || $c$

<details>
<summary>Referring a customer to an appraiser or estate attorney</summary>

*[Embedded excerpt from: Referrals]*

</details>$c$, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id='864124937' AND manual_type='excerpt';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Inbound Calls fragment not found'; END IF;

  ------------------------------------------------------------------
  -- 7. Re-parent for lineage, then convert to fragments.
  ------------------------------------------------------------------
  UPDATE manuals SET parent_page_id = v_dq  WHERE agency_id=v_agency AND confluence_page_id IN ('878084261','878084356','864190563');
  UPDATE manuals SET parent_page_id = v_up  WHERE agency_id=v_agency AND confluence_page_id IN ('878575765','878346444','878575747','878313536');
  UPDATE manuals SET parent_page_id = v_dr  WHERE agency_id=v_agency AND confluence_page_id IN ('1587806454','1478524929','870318291');
  UPDATE manuals SET parent_page_id = '878084192' WHERE agency_id=v_agency AND confluence_page_id IN ('1567719425','1689944066');
  UPDATE manuals SET parent_page_id = '878084356' WHERE agency_id=v_agency AND confluence_page_id = '878576139';
  UPDATE manuals SET parent_page_id = '864124937' WHERE agency_id=v_agency AND confluence_page_id = '1505591297';

  -- Any [Included from: X] aimed at a converting page must become an excerpt marker.
  FOR v_title IN SELECT title FROM manuals WHERE agency_id=v_agency AND confluence_page_id = ANY(v_frag)
  LOOP
    UPDATE manuals
       SET content = replace(content, '[Included from: '||v_title||']', '[Embedded excerpt from: '||v_title||']'),
           updated_at = now()
     WHERE agency_id=v_agency AND content LIKE '%[Included from: '||v_title||']%';
  END LOOP;

  UPDATE manuals SET manual_type='excerpt', updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id = ANY(v_frag);

  ------------------------------------------------------------------
  -- 8. Shells go. Root gets a real body. Remaining children get an order.
  ------------------------------------------------------------------
  DELETE FROM manuals WHERE agency_id=v_agency AND confluence_page_id = ANY(v_shells);

  UPDATE manuals
     SET content = 'The behind-the-scenes work that keeps the office running: the daily queues, the monthly rotation, quoting support, the physical office, and what we do when a storm hits.',
         updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id=v_ops;

  UPDATE manuals SET sort_order=20, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='878084192';
  UPDATE manuals SET sort_order=30, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='812318730';
  UPDATE manuals SET sort_order=70, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='982581354';
END $$;
