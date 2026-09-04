-- Retention section restructure (Peter, 2026-09-04).
--
-- Reception, Retention Tasks and Retention Appointments collapse into ONE
-- top-level "Retention" section with three checklists under it — Inbound,
-- Outbound Touches, Appointments — plus Automated Task Closure in ECRM.
-- Every subpage that a checklist pulls in becomes an excerpt fragment (hidden
-- from the tree, embedded where it is used). Reference-only pages become
-- fragments embedded on the page that needs them. Operations Processes, which
-- had been parked under Retention Tasks with 20+ non-retention descendants,
-- becomes its own top-level section.
--
-- Duplicates collapsed to one copy each:
--   claims touches  — Claims Touches page + Retention Tasks body + Claims
--                     Follow-Up Process → one Claims Touches fragment;
--                     Claims Follow-Up Process row deleted.
--   late pay        — Retention Tasks cadence wins (Peter ruling); the Late
--                     Pay Process page keeps its info box and texts, drops its
--                     own table and its first/second/third-time talk tracks.
--   shared folders  — Retention Tasks folder-working text folded into the
--                     Outlook Shared Folders fragment.
--
-- Marker mechanics: [Included from: X] resolves against rows of the current
-- manual_type; [Embedded excerpt from: X] resolves against manual_type=
-- 'excerpt'. Every marker pointing at a converted title is rewritten in the
-- same transaction (same approach as 20260809221515). The renderer change in
-- commit a3f1f859 lets a fragment include a page (Inbound Calls includes
-- Mortgage/Loan Protection), so that chain keeps rendering after conversion.
-- Three markers that were already broken (an Included-from marker pointing
-- at an excerpt row) are fixed in the same sweep: BOD Message Process →
-- Account Change, Payment Processes → Payment Script, Renewal Premium Change
-- Process → Premium Change Script.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_root   text := '1726546221';   -- Retention Tasks → Retention (section root)
  v_inb    text := '1746010123';   -- Reception → Inbound
  v_appt   text := '1747025922';   -- Retention Appointments → Appointments
  v_ops    text := '315523073';    -- Operations Processes → top level
  v_atc    text := '2540109825';   -- Automated Task Closure in ECRM
  v_outb   text := 'newtworks-native-outbound-touches-2026-09-04';
  v_convert text[] := ARRAY[
    -- Reception children
    '864124937','864157781','864157764','870318462','915767342','929464815','1440776217',
    -- Retention Tasks children
    '1912274945','1895202817','302120963','1432387585','869728346','1770029058',
    -- the five ECRM task lists under Automated Task Closure
    '2538438669','2539454507','2538504198','2537652246','2539454498',
    -- Retention Appointments children
    '1542094849','1478033409','982581320','929464910',
    -- DSS Processes (from Operations > Service Handling)
    '1461387265'
  ];
  v_title  text;
  v_n      int;
  v_old    text;
  v_new    text;
  v_note   text;
  v_survey2 text;
  v_survey3 text;
  v_folders text;
BEGIN
  ------------------------------------------------------------------
  -- 0. Guards: every row this migration touches must exist and be active.
  ------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND manual_type = 'processes' AND is_active
     AND confluence_page_id = ANY(v_convert);
  IF v_n <> array_length(v_convert, 1) THEN
    RAISE EXCEPTION 'Expected % convert targets, found %', array_length(v_convert, 1), v_n;
  END IF;
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND manual_type = 'processes' AND is_active
     AND confluence_page_id IN (v_root, v_inb, v_appt, v_ops, v_atc, '870351044', '866811973', '870350997', '878313536', '982581354', '878084261', '870351216', '870351246');
  IF v_n <> 13 THEN
    RAISE EXCEPTION 'Expected 13 host rows, found %', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id = v_agency AND manual_type = 'excerpt' AND is_active
     AND lower(title) IN (SELECT lower(title) FROM manuals WHERE agency_id = v_agency AND confluence_page_id = ANY(v_convert));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'Excerpt title collision: % rows', v_n;
  END IF;

  ------------------------------------------------------------------
  -- 1. Claims Touches — one page for the whole claims follow-up.
  --    Pulls the survey scripts out of the old page, the task mechanics out
  --    of Claims Follow-Up Process, and the find-new-claims steps out of the
  --    Retention Tasks body. Text templates come from the Claims Touch 1/2/3
  --    excerpts (which already carried them).
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '929464815';
  v_note    := substring(v_old from '(> \*\*📝 NOTE\*\*.*?)\n\n### Touch 1');
  v_survey2 := substring(v_old from '<details>\n<summary>Touch 2</summary>\n\n(.*?)\n\n\*\[Included from: Appointments Set & Create\]\*');
  v_survey3 := substring(v_old from '<details>\n<summary>Touch 3</summary>\n\n(.*?)\n\n</details>');
  IF v_note IS NULL OR v_survey2 IS NULL OR v_survey3 IS NULL THEN
    RAISE EXCEPTION 'Claims Touches anchors not found (note=%, s2=%, s3=%)', v_note IS NOT NULL, v_survey2 IS NOT NULL, v_survey3 IS NOT NULL;
  END IF;

  v_new := $c$> **ℹ️ INFO**
>
> **Purpose:** Customer filed a claim through one of the non-agency channels, and we want to get in touch to start our follow-up process

$c$ || v_note || $c$

Claim time is the best time to set up appointments and uncover exposures

If we uncover claims difficulties, be sure to handle them with confidence and inform the agent

If you believe a claim should be escalated to the agent, don’t hesitate to suggest it and give reasons why

When asking claims for information, find the adjuster/handler and email them along with a CC of their supervisor

<details>
<summary>Find new claims</summary>

Copy “Open Claims” list view

- Add field “Date Recorded”
- Sort by “Date Recorded” descending
- View the claim
- Create a task to follow 3 Claims touches to check on the customer, connect them with claims, and setup a claims review with me
- Mark the claim as “Reviewed”

Handle any claims concerns that come up along the way

Contact the [Claims Liaison](https://collab.sfcollab.org/sites/WSS005829/DC/CGI/SitePages/Active%20Agency%20Catastrophe%20Claims%20Liaison%20Lines.aspx) if needed

</details>

<details>
<summary>Touch 1: same day the claim is filed</summary>

**Create a task**

- Assign to Account Manager
- Subject: CLAIMS T1
- Due date = TODAY
- Call this afternoon

**How do we proceed?** That depends on how we found out about the claim.

- **Reported through the agency:** follow the initial loss reporting steps in Inbound Calls
- **Reported directly to claims:** text/email the customer

*[Embedded excerpt from: Claims Touch 1]*

**Now pend out the same task:**

- Assign to Account Manager
- Subject: CLAIMS T2
- Due date = seven days from date of loss (or three days after today, whichever is later)

</details>

<details>
<summary>Touch 2: seven days after</summary>

Pend task if:

- Claim is still open: One week

*[Embedded excerpt from: Claims Touch 2]*

If we haven’t heard from them by the afternoon, call for the second touch.

Did we connect with them? Run the survey:

$c$ || v_survey2 || $c$

*[Embedded excerpt from: Appointments Set & Create]*

Pend out the current task:

- Subject: CLAIMS T3
- Due date = thirty days from date of loss

</details>

<details>
<summary>Touch 3: thirty days after</summary>

Pend task if:

- Claim is still open: One week
- Claim is still being subrogated: One month

*[Embedded excerpt from: Claims Touch 3]*

If we haven’t heard from them by the afternoon, call for the third touch.

Did we connect with them? Run the survey:

$c$ || v_survey3 || $c$

</details>$c$;

  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '929464815';

  -- Claims Follow-Up Process is fully absorbed above.
  DELETE FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '870351044';
  UPDATE manuals SET content = replace(content, E'- Claims Follow-Up Process\n', ''), updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '870350997';

  ------------------------------------------------------------------
  -- 2. Late Pay Process — Retention Tasks cadence and rules replace the
  --    page's own table and its first/second/third-time talk tracks.
  ------------------------------------------------------------------
  v_new := $c$> **ℹ️ INFO**
>
> When a late pay task comes in, follow these touches and discuss the topics below based on how many times this customer has been late.
>
> Any appointments set from this process do not count as part of the 100 appointment names for the month.

| **Day 1** | **Day 7** | **Day before cancel date** | **Week after cancel date** |
| --- | --- | --- | --- |
| Text/Call/Email | Text/Email | Call and final text and email | Call, reassigned back to your office 7 days prior to app date as WINBACK |

If the customer is a third time late pay, we'll reach out proactively five days ahead so they pay before it lapses

- If we need to, we can bump back their due date as long as they keep paying when they used to
- After six months, we'll stop the reminders and let them know that we’re stopping

Alternatively, they can get on recurring

If they get into a new bad habit after the above or they start paying later after we’ve bumped back their due date, we'll force them onto RecMo

All team have authority to process one late payment fee and one recurring payment fee per HH if we have WRITTEN confirmation of their understanding that it is a one-time waiver

<details>
<summary>Late Payment</summary>

*[Embedded excerpt from: Late Payment]*

</details>$c$;

  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '1912274945';

  ------------------------------------------------------------------
  -- 3. Outlook Shared Folders — fold in the folder-working text from the
  --    Retention Tasks body, ahead of the outbound-fax section.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = v_root;
  v_folders := substring(v_old from '\*\*Shared Outlook Folders\*\*\n\n(Each morning, Retention works emails.*?- SFPP Forms needed)');
  IF v_folders IS NULL THEN
    RAISE EXCEPTION 'Retention Tasks shared-folders block not found';
  END IF;

  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '864157764';
  IF position(E'### Sending an outbound fax' IN v_old) = 0 THEN
    RAISE EXCEPTION 'Outlook Shared Folders fax anchor not found';
  END IF;
  UPDATE manuals
     SET content = replace(v_old, E'### Sending an outbound fax',
                           E'### Working the @ folders\n\n' || v_folders || E'\n\n### Sending an outbound fax'),
         updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '864157764';

  ------------------------------------------------------------------
  -- 4. Retention root (was Retention Tasks): scope map stays, the three
  --    duplicated blocks point at the single fragment instead.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = v_root;

  -- 4a. late-pay cell → pointer
  v_new := regexp_replace(v_old,
    '\*\*Day 1\*\* – Text/Call/Email.*?one-time waiver \|',
    'Follow the Late Pay Process (Outbound Touches) |');
  IF v_new = v_old THEN RAISE EXCEPTION 'late-pay cell anchor not found'; END IF;
  v_old := v_new;

  -- 4b. shared-folders section → embed
  v_new := regexp_replace(v_old,
    '\*\*Shared Outlook Folders\*\*\n\nEach morning, Retention works emails.*?- SFPP Forms needed',
    E'**Shared Outlook Folders**\n\n<details>\n<summary>Outlook Shared Folders</summary>\n\n*[Embedded excerpt from: Outlook Shared Folders]*\n\n</details>');
  IF v_new = v_old THEN RAISE EXCEPTION 'shared-folders anchor not found'; END IF;
  v_old := v_new;

  -- 4c. Level 3 claims block → embed
  v_new := regexp_replace(v_old,
    '<details>\n<summary>Claims</summary>\n\n.*?</details>',
    E'<details>\n<summary>Claims Touches</summary>\n\n*[Embedded excerpt from: Claims Touches]*\n\n</details>');
  IF v_new = v_old THEN RAISE EXCEPTION 'claims block anchor not found'; END IF;
  v_old := v_new;

  -- 4d. document types reference under the Certificates of Insurance line
  v_new := replace(v_old, 'rush through underwriting.)',
    E'rush through underwriting.)\n\n<details>\n<summary>Types of Insurance Documents Needed</summary>\n\n*[Embedded excerpt from: Types of Insurance Documents Needed]*\n\n</details>');
  IF v_new = v_old THEN RAISE EXCEPTION 'COI anchor not found'; END IF;

  UPDATE manuals
     SET title = 'Retention', content = v_new, sort_order = 40, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = v_root;

  ------------------------------------------------------------------
  -- 5. Inbound (was Reception): verify & remind moves to Appointments.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = v_inb;
  v_new := regexp_replace(v_old,
    '<details>\n<summary>Verify &amp; remind upcoming appointments</summary>\n\n\*\[Included from: Appointments Verify & Remind\]\*\n\n</details>\n\n\n\n', '');
  IF v_new = v_old THEN RAISE EXCEPTION 'verify & remind block not found on Reception'; END IF;
  UPDATE manuals
     SET title = 'Inbound', content = v_new, parent_page_id = v_root, sort_order = 10, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = v_inb;

  ------------------------------------------------------------------
  -- 6. Outbound Touches — new checklist.
  ------------------------------------------------------------------
  INSERT INTO manuals (agency_id, manual_type, title, content, content_format, confluence_page_id, parent_page_id,
                       sort_order, icon, divider_after, version, is_active, fetched_at, created_at, updated_at)
  VALUES (v_agency, 'processes', 'Outbound Touches', $c$
**Checklist**

<details>
<summary>Work new claims and run the three claims touches</summary>

*[Embedded excerpt from: Claims Touches]*

</details>



<details>
<summary>Text customers whose policies are renewing</summary>

*[Embedded excerpt from: Renewal]*

</details>



<details>
<summary>Work late pays</summary>

*[Embedded excerpt from: Late Pay Process]*

</details>



<details>
<summary>Send the annual PLUP/CLUP review email</summary>

*[Embedded excerpt from: PLUP/CLUP Review]*

</details>



<details>
<summary>Drive Safe &amp; Save reminders and beacon reorders</summary>

*[Embedded excerpt from: DSS Processes]*

</details>$c$, 'markdown', v_outb, v_root, 20, '📤', false, 1, true, now(), now(), now());

  ------------------------------------------------------------------
  -- 7. Appointments (was Retention Appointments).
  ------------------------------------------------------------------
  UPDATE manuals
     SET title = 'Appointments', parent_page_id = v_root, sort_order = 30, updated_at = now(),
         content = $c$
**Checklist**

<details>
<summary>Set &amp; create appointments</summary>

*[Embedded excerpt from: Appointments Set & Create]*

</details>



<details>
<summary>Verify &amp; remind upcoming appointments</summary>

*[Embedded excerpt from: Appointments Verify & Remind]*

</details>



<details>
<summary>Welcome new customers</summary>

*(This script lives in the Admin manual under "Welcome" — not shown here since it's a different manual.)*

</details>



<details>
<summary>Review auto and HO policies after a claim or prior to renewal</summary>

*[Embedded excerpt from: Review Policy]*

</details>



<details>
<summary>Review new young driver tips</summary>

*[Embedded excerpt from: Review New Young Driver]*

</details>



<details>
<summary>Review life policies</summary>

*[Embedded excerpt from: Life Review]*

</details>



<details>
<summary>Keep households and life policies from leaving</summary>

*[Embedded excerpt from: Save Household]*

</details>$c$
   WHERE agency_id = v_agency AND confluence_page_id = v_appt;

  ------------------------------------------------------------------
  -- 8. Automated Task Closure in ECRM stays a page; the five lists embed.
  ------------------------------------------------------------------
  UPDATE manuals
     SET sort_order = 40, updated_at = now(),
         content = content || $c$

<details>
<summary>Auto Tasks</summary>

*[Embedded excerpt from: Auto Tasks]*

</details>

<details>
<summary>Billing Tasks</summary>

*[Embedded excerpt from: Billing Tasks]*

</details>

<details>
<summary>Fire Tasks</summary>

*[Embedded excerpt from: Fire Tasks]*

</details>

<details>
<summary>Health Tasks</summary>

*[Embedded excerpt from: Health Tasks]*

</details>

<details>
<summary>Life Tasks</summary>

*[Embedded excerpt from: Life Tasks]*

</details>$c$
   WHERE agency_id = v_agency AND confluence_page_id = v_atc;

  ------------------------------------------------------------------
  -- 9. Operations Processes → top level. Service Handling loses DSS.
  ------------------------------------------------------------------
  UPDATE manuals SET parent_page_id = NULL, sort_order = 50, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = v_ops;
  UPDATE manuals SET content = replace(content, E'- DSS Processes\n', ''), updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '866811973';

  ------------------------------------------------------------------
  -- 10. Reference fragments get a home.
  ------------------------------------------------------------------
  UPDATE manuals
     SET content = content || $c$

<details>
<summary>If our office number shows as spam on customers' phones</summary>

*[Embedded excerpt from: SPAM Listings - Registering Office Phone Number]*

</details>$c$, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '878313536';

  SELECT content INTO v_old FROM manuals WHERE agency_id = v_agency AND confluence_page_id = '982581354';
  v_new := replace(v_old, E'<details>\n<summary>In-Book Refi Campaign Contact Script</summary>',
    E'<details>\n<summary>Build the campaign call list in ECRM</summary>\n\n*[Embedded excerpt from: Policyholder List Creation]*\n\n</details>\n\n<details>\n<summary>In-Book Refi Campaign Contact Script</summary>');
  IF v_new = v_old THEN RAISE EXCEPTION 'refi script anchor not found'; END IF;
  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = '982581354';

  ------------------------------------------------------------------
  -- 11. Repoint every marker at a converted title, then convert.
  ------------------------------------------------------------------
  FOR v_title IN
    SELECT title FROM manuals WHERE agency_id = v_agency AND confluence_page_id = ANY(v_convert)
  LOOP
    UPDATE manuals
       SET content = replace(content, '[Included from: ' || v_title || ']', '[Embedded excerpt from: ' || v_title || ']'),
           updated_at = now()
     WHERE agency_id = v_agency
       AND content LIKE '%[Included from: ' || v_title || ']%';
  END LOOP;

  UPDATE manuals SET manual_type = 'excerpt', updated_at = now()
   WHERE agency_id = v_agency AND confluence_page_id = ANY(v_convert);

  ------------------------------------------------------------------
  -- 12. Same-class sweep: Included-from markers that pointed at excerpt
  --     rows all along and never rendered.
  ------------------------------------------------------------------
  FOR v_title IN SELECT unnest(ARRAY['Account Change', 'Payment Script', 'Premium Change Script'])
  LOOP
    UPDATE manuals
       SET content = replace(content, '[Included from: ' || v_title || ']', '[Embedded excerpt from: ' || v_title || ']'),
           updated_at = now()
     WHERE agency_id = v_agency
       AND content LIKE '%[Included from: ' || v_title || ']%';
  END LOOP;
END $$;
