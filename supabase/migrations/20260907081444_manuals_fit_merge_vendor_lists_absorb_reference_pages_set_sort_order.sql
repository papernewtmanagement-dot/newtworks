-- FIT Conversations cleanup (Peter, 2026-09-04).
--
-- Peter's correction: Simple Fire FIT, Simple Health FIT and Simple Mortgage FIT
-- are FOLDERS, not shell pages. They stay exactly as they are. Only these three
-- things change.
--
-- 1. APPRAISER LISTS MERGED. There were two, in two different sections:
--    PAP Appraisers (under Specifications and Referrals) and the Appraisals
--    section of the Referrals fragment (embedded on Inbound Calls). Georgia
--    Jobes appears in both — as a bare link in one and as Impressa Group with
--    full detail in the other. Roofer Referrals was a third vendor list sitting
--    apart from both. All three now live in the one Referrals fragment, which
--    already had the estate attorneys. Nothing was dropped; the PAP Appraisers
--    links that were not already covered are kept as online appraisers and a
--    directory to search. PAP Appraisers and Roofer Referrals rows are deleted.
--
-- 2. SPECIFICATIONS AND REFERRALS pulls its children up into itself, per Peter.
--    Apartment Specifications and Mortgagee Specifications become fragments and
--    render on the parent page along with the merged Referrals list, so the
--    whole reference set is one page instead of four one-item subpages.
--    Jackson Account gets the same treatment on Simple Investing FIT.
--
-- 3. SORT ORDER. Most of FIT Conversations had none, so children fell in
--    whatever order they loaded. Ordered by how the book is sold: the lead
--    cadence first, then Auto, Fire, Life, Health, Investing, Mortgage.

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_specs text := '843415603';
  v_old text; v_new text; v_n int;
BEGIN
  ------------------------------------------------------------------
  -- 0. Guards
  ------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND is_active AND manual_type='processes'
     AND confluence_page_id IN ('1587675137','1587806406','1892417537','2149220358','1501200385',v_specs);
  IF v_n <> 6 THEN RAISE EXCEPTION 'Expected 6 reference pages, found %', v_n; END IF;

  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND manual_type='excerpt' AND is_active
     AND lower(trim(title)) IN ('apartment specifications','mortgagee specifications','jackson account');
  IF v_n <> 0 THEN RAISE EXCEPTION 'Excerpt title collision: % row(s)', v_n; END IF;

  -- Nothing may point at the two lists being folded away.
  SELECT count(*) INTO v_n FROM manuals
   WHERE agency_id=v_agency AND is_active
     AND (content ILIKE '%from: PAP Appraisers]%' OR content ILIKE '%from: Roofer Referrals]%');
  IF v_n <> 0 THEN RAISE EXCEPTION 'PAP Appraisers or Roofer Referrals is referenced (% rows)', v_n; END IF;

  ------------------------------------------------------------------
  -- 1. One vendor list: appraisers, roofers, estate attorneys.
  ------------------------------------------------------------------
  SELECT content INTO v_old FROM manuals
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='Referrals';
  IF v_old IS NULL THEN RAISE EXCEPTION 'Referrals fragment not found'; END IF;
  IF position(E'### Estate Planning Attorneys' IN v_old) = 0 THEN
    RAISE EXCEPTION 'Referrals estate attorney anchor not found';
  END IF;

  v_new := replace(v_old, E'### Estate Planning Attorneys',
$c$#### Vogt Auction Galleries

- <https://www.vogtauction.com/page/valuations>

#### Online appraisers

- [https://www.valuepros.com/personal-property](https://www.valuepros.com/personal-property/)
- <https://www.valuemystuff.com/us>

#### Finding another appraiser

- <https://www.isa-appraisers.org/find-an-appraiser>

### Roofers

Jeremy Morfin at covR Roofing 210-446-3064

> My name is Jeremy Morfin - I am the Sales Manager here at covR Roofing. I have stopped by a few times and dropped off flyers and cards. We are a local roofing company that assists several agents all over San Antonio. We offer free roofing inspections and would like to be a trusted resource for you and your homeowners.
>
> We understand how sensitive claim frequency is in this market. We do not encourage unnecessary claims - if a roof is repairable, we say so.
>
> Client retention is critical to your agency and we want to support that with quality service and quality roof systems. We offer a free upgrade from 3tab to an IR upgrade and a 10 year workmanship warranty. We're here to be a trusted resource, not a disruption.

---

Jacob LaRue at Honeydew Roofing 210-504-8709

> **Customer recommendation:** "I just had Honeydew Roofing come to look at my roof. They found just a few nail pops and sealed them. They said my roof should be good for another 7 years. I recommend them. They didn't try to sell me a new roof."

---

Presidio Roofing 210-899-5600

---

James Lozano at WeatherTech Roofing 210-557-6917

### Estate Planning Attorneys$c$);
  IF v_new = v_old THEN RAISE EXCEPTION 'Referrals merge failed'; END IF;

  UPDATE manuals SET content = v_new, updated_at = now()
   WHERE agency_id=v_agency AND manual_type='excerpt' AND title='Referrals';

  DELETE FROM manuals WHERE agency_id=v_agency AND confluence_page_id IN ('1892417537','2149220358');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 2 THEN RAISE EXCEPTION 'Expected to delete 2 vendor pages, deleted %', v_n; END IF;

  ------------------------------------------------------------------
  -- 2. Specifications and Referrals absorbs its children.
  ------------------------------------------------------------------
  UPDATE manuals SET manual_type='excerpt', parent_page_id=v_specs, sort_order=NULL, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id IN ('1587675137','1587806406');

  UPDATE manuals SET updated_at=now(), content = $c$<details>
<summary>Apartment specifications</summary>

*[Embedded excerpt from: Apartment Specifications]*

</details>

<details>
<summary>Mortgagee specifications</summary>

*[Embedded excerpt from: Mortgagee Specifications]*

</details>

<details>
<summary>Appraisers, roofers, and estate attorneys</summary>

*[Embedded excerpt from: Referrals]*

</details>$c$
   WHERE agency_id=v_agency AND confluence_page_id=v_specs;

  -- Jackson Account is product reference, not a conversation.
  UPDATE manuals SET manual_type='excerpt', parent_page_id='1530134531', sort_order=NULL, updated_at=now()
   WHERE agency_id=v_agency AND confluence_page_id='1501200385';

  UPDATE manuals SET updated_at=now(), content = content || $c$

<details>
<summary>Jackson account — products, word tracks, and applications</summary>

*[Embedded excerpt from: Jackson Account]*

</details>$c$
   WHERE agency_id=v_agency AND confluence_page_id='1530134531';

  ------------------------------------------------------------------
  -- 3. Sort order.
  ------------------------------------------------------------------
  -- FIT Conversations, in the order the book gets sold
  UPDATE manuals SET sort_order=10, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='2677309441';
  UPDATE manuals SET sort_order=20, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='2583035905';
  UPDATE manuals SET sort_order=30, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='2474475654';
  UPDATE manuals SET sort_order=40, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1702035459';
  UPDATE manuals SET sort_order=50, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='2716762128';
  UPDATE manuals SET sort_order=60, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1530134531';
  UPDATE manuals SET sort_order=70, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='newtworks-native-simple-mortgage-fit';

  -- Health, Life, Investing children
  UPDATE manuals SET sort_order=10, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='2588246020';
  UPDATE manuals SET sort_order=20, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='2588770305';
  UPDATE manuals SET sort_order=10, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1599602715';
  UPDATE manuals SET sort_order=20, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1851588610';
  UPDATE manuals SET sort_order=10, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='2588770324';

  -- Quicken mortgage workflow runs in numbered order
  UPDATE manuals SET sort_order=5,  updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1283522585';
  UPDATE manuals SET sort_order=10, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1283522594';
  UPDATE manuals SET sort_order=20, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1282998287';
  UPDATE manuals SET sort_order=30, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='929497389';
  UPDATE manuals SET sort_order=40, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='929497396';
  UPDATE manuals SET sort_order=50, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='932806665';
  UPDATE manuals SET sort_order=60, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1445888001';

  -- Daily Kickoff pick-from libraries
  UPDATE manuals SET sort_order=10, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='newtworks-native-objection-bank';
  UPDATE manuals SET sort_order=20, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='newtworks-native-icebreakers';
  UPDATE manuals SET sort_order=30, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1629978625';
  UPDATE manuals SET sort_order=40, updated_at=now() WHERE agency_id=v_agency AND confluence_page_id='1708163086';
END $$;

-- Applied separately: Sales Process had no sort order either.
UPDATE manuals SET sort_order=10, updated_at=now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '815628349';
