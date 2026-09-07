-- The two things left unmerged in the Operations restructure (Peter: handle them).
--
-- 1. ADM LEAD CONVERSION — genuine duplication, merged.
--    Background Tasks week 3 and Quote Support both describe the same job.
--    Neither is complete on its own: Quote Support has the campaign filter and
--    the oldest-to-newest sort that Background Tasks lacks; Background Tasks has
--    the whole conversion procedure that Quote Support lacks. One "Convert ADM
--    Leads" fragment now carries both, embedded in both places. NOTHING was
--    dropped — Quote Support's "create an opportunity to call" is kept inside
--    the ex-customer branch alongside Background Tasks' Win-Back handling, since
--    only Peter can say whether those are one action or two.
--
-- 2. DO-NOT-CONTACT CLEANUP — NOT duplication, left as two separate jobs.
--    On close reading these are different lists on different cadences:
--    Background Tasks week 2 works the #Do Not Solicit opportunity list monthly
--    (reclassify to Existing Business, or remove from book). Quote Support does
--    two other passes: written consent requests for do-not-call opportunities
--    closed in the last week, and closing do-not-call opportunities older than
--    ninety days. The only thing they share is the removal rule, which is
--    already the one When to Delete a Lead fragment embedded on both pages.
--    What made them look like duplicates is that Quote Support was an unlabeled
--    wall of twelve paragraph blocks, so this migration gives every block a
--    heading. No wording is changed — only section labels are added.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_old text; v_new text; v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND is_active AND lower(trim(title))='convert adm leads';
  IF v_n <> 0 THEN RAISE EXCEPTION 'Convert ADM Leads already exists'; END IF;

  ------------------------------------------------------------------
  -- 1. The merged fragment.
  ------------------------------------------------------------------
  INSERT INTO manuals (agency_id, manual_type, title, content, content_format, confluence_page_id,
                       parent_page_id, sort_order, version, is_active, fetched_at, created_at, updated_at)
  VALUES (v_agency, 'excerpt', 'Convert ADM Leads', $c$- **ECRM Campaign List:** #Corporate Leads
- Filter Type = Corporate Leads, Campaign Name contains “ADM”
- Sort from oldest to newest
- Click on a campaign
- Click on the lead name
- Click "Convert to Prospect" button at top right
- It will ask you for a LOB, choose "Auto"
- It will put you on the new account page, hit "Save As Prospect"
- When the Do Not Share box pops up, leave box unchecked and hit "No"
- Close out of the quote window that pops up
- This will turn the lead into an Account and drop you into the account
- Hover over "Agent" so the listing of past and present agent relationships is displayed
- Check for "Ex-customer"
- If ex-customer:
  - Change opportunity and set the type to "Win-Back"
  - Assign the opportunity by alphabet
  - Create an opportunity to call
- Else: Set stage to "New"
- Once the Campaign has zero leads, delete it$c$,
    'markdown', 'newtworks-native-convert-adm-leads-2026-09-04', '812318730', NULL, 1, true, now(), now(), now());

  ------------------------------------------------------------------
  -- 2. Background Tasks week 3 points at the fragment.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id=v_agency AND confluence_page_id='812318730';
  v_new := regexp_replace(v_old,
    '\*\*Week 3:\*\* Convert ADM Leads\n\n- \*\*ECRM Campaign List:\*\*.*?- Once the Campaign has zero leads, delete it',
    E'**Week 3:** Convert ADM Leads\n\n<details>\n<summary>How to convert them</summary>\n\n*[Embedded excerpt from: Convert ADM Leads]*\n\n</details>');
  IF v_new = v_old THEN RAISE EXCEPTION 'Background Tasks week 3 block not found'; END IF;
  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id=v_agency AND confluence_page_id='812318730';

  ------------------------------------------------------------------
  -- 3. Quote Support: same wording, now in labelled sections.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals WHERE agency_id=v_agency AND confluence_page_id='878084192';
  IF position('Convert ADM Leads' IN v_old) = 0 THEN
    RAISE EXCEPTION 'Quote Support ADM block not found';
  END IF;

  UPDATE manuals SET updated_at = now(), content = $c$**Checklist**

<details>
<summary>Check the lead providers for credit holds</summary>

Check the following internet lead providers

Sort by most recent date

Look at only the leads that came in yesterday or any that have FU tasks

Look for credit pending or credit rejected statuses

If rejected, appeal

- Appeal button is often available
- If not, email the list of denied to Alvi to email that group appeal

If pending, create a task to check that lead again tomorrow

*(Page not yet in Newtworks: "Internet Lead Providers (ILPs)")*

</details>



<details>
<summary>Quote and send today's new leads</summary>

Run quotes on all new ILP and [StateFarm.com](http://StateFarm.com) leads from today

- Use ONLY the drivers they supplied
- All possible discounts
- Lowest possible coverages

Text: Good news, your quote could be $XX each month!

Email that quote

Print and mail that quote

</details>



<details>
<summary>Close out or request a refund on bad leads</summary>

If ILP is $500 or more per month per car, close them out

- Filters should have blocked out bad ones, so this is likely just a matter of bad CRI
- If they did not meet the filters for that ILP, request a refund

If [StateFarm.com](http://StateFarm.com), decide if they’re competitive based on other factors (e.g. $500 is low for a DUI)

</details>



<details>
<summary>Fill in missing contact details</summary>

If missing name, phone, or address, run them through TruePeopleSearch

- Search order: Reverse Phone > Reverse Address > Name
- If the name and age come up, we can be confident enough that this is who we’re looking for
- Enter into ECRM the name, phone, and address that we found here
- If the TruePeopleSearch record is missing name, phone, or address, request a refund

</details>



<details>
<summary>Follow up at 7, 14, and 28 days</summary>

View all initial contact ILP and [StateFarm.com](http://StateFarm.com) leads created 7 days ago, 14 days ago, and 28 days ago

Find the complete quote saved in their folder

Email the quote to all of them

Mail the quote for the people in the 28 days ago category

</details>



<details>
<summary>Convert ADM leads</summary>

*[Embedded excerpt from: Convert ADM Leads]*

</details>



<details>
<summary>Ask recently closed do-not-call leads for written consent</summary>

Run a list of all do-not-call opportunities closed in the last week

Send written request to contact

</details>



<details>
<summary>Close do-not-call opportunities older than ninety days</summary>

Run a list of all do-not-call opportunities created ninety days or more ago

Close the opportunity

If the customer has no products with us and no other opportunities created less than ninety days ago, remove them from the book

</details>



<details>
<summary>How long underwriting has on a new policy</summary>

*[Embedded excerpt from: P&C Underwriting Timing]*

</details>



<details>
<summary>When to delete a lead</summary>

*[Embedded excerpt from: When to Delete a Lead]*

</details>$c$
   WHERE agency_id=v_agency AND confluence_page_id='878084192';
END $$;
