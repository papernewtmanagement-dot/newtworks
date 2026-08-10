-- Peter directive 2026-08-10, scope clarification on the 2026-07-08 no-horizontal-line rule:
-- that rule governs Claude's OWN styling choices (never add dividers on its own
-- initiative), not Peter's explicit orders. The CHECK constraint added on
-- 2026-07-08 (migration 20260708143000) could not make that distinction — it
-- rejected the write regardless of who asked for it, so it blocked a direct
-- order. Dropping it; the rule survives as a behaviour rule in persistent_memory
-- "Manuals Rulebook" with the clarified scope recorded.
--
-- Then: horizontal dividing lines between the sections of PAP Appraisers, and
-- between each referral on Roofer Referrals, as ordered. No other content change
-- on either page — every link, name, phone number and quote carried verbatim.

ALTER TABLE public.manuals
  DROP CONSTRAINT IF EXISTS manuals_no_hr_divider;

UPDATE public.manuals
SET content = $md$Online Appraisers:

[https://www.valuepros.com/personal-property](https://www.valuepros.com/personal-property/)

<https://www.valuemystuff.com/us>

---

Good local appraisers:

[https://georgiajobes.com](https://georgiajobes.com/)

<https://www.vogtauction.com/page/valuations>

---

Website to search for appraisers:

<https://www.isa-appraisers.org/find-an-appraiser>
$md$,
    version = COALESCE(version, 0) + 1,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'processes'
  AND confluence_page_id = '1892417537'
  AND is_active = true;

UPDATE public.manuals
SET content = $md$Jeremy Morfin at covR Roofing 210-446-3064

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
$md$,
    version = COALESCE(version, 0) + 1,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'processes'
  AND confluence_page_id = '2149220358'
  AND is_active = true;
