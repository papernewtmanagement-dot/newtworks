-- Peter directive 2026-08-10, processes manual, Simple Fire FIT subtree.
-- 1. Rename "Fire Specifications & Referrals" (843415603) to "Fire Info".
--    Rename audit run first: zero pg_proc hits, zero manuals.content references
--    to either the old title or page id 843415603, no active-title collision.
-- 2. Rebuild "Apartment Specifications" (1587675137): strip the 40 header-only
--    Contacts/Visits tables, add a top-of-page quick-reference table, give the
--    per-complex spec tables real header rows, and use <br> inside cells so the
--    multi-line addresses actually break (the Confluence port used trailing
--    double-spaces, which do nothing inside a markdown table cell).
--    Every stored value carried across verbatim. Nothing dropped but empty rows.

UPDATE public.manuals
SET title = 'Fire Info',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'processes'
  AND confluence_page_id = '843415603'
  AND is_active = true;

UPDATE public.manuals
SET content = $md$List of apartment complexes we have binding specifications on file for, with contact and visit history where we have it.

## Quick Reference

| Complex | Minimum liability | Recommended liability | Sprinklers |
| --- | --- | --- | --- |
| Abbey at Stone Oak, The | $100,000 | $500,000 | FULL |
| Anthony, The | $100,000 | $500,000 | ? |
| Boulevard at Sonterra, The | $100,000 | $500,000 | Partial |
| Creekstone | $100,000 | $500,000 | Partial |
| Crest Round Rock | $100,000 | $500,000 | Partial |
| Encore 281 | $100,000 | $500,000 | Full |
| Grandview Landmark | $100,000 | $500,000 | Partial |
| Hawthorne at Victoria | $100,000 | $500,000 | Full |
| Marquis at Stone Oak | $100,000 | $500,000 | Partial |
| Montecristo Apartments | $100,000 | $500,000 | Partial |
| Retreat at the Rim Apartments | $100,000 | $500,000 | Full |
| Savannah Oaks | $100,000 | $500,000 | Partial |
| Sendera Landmark | $100,000 | $500,000 | Partial |
| Toscana at Sonterra | $100,000 | $500,000 | Full |
| Tribute at the Rim | $100,000 | $500,000 | Full |
| Vantage at Bulverde | $100,000 | $500,000 | ? |
| Ventura Ridge | $100,000 | $300,000 (maximum they'll allow?!?) | Partial |
| Vineyard Springs | $100,000 | $500,000 | Full |
| Viridian | $100,000 | $500,000 | Partial |
| West Oaks | $100,000 | $500,000 | Partial |

## Abbey at Stone Oak, The

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | FULL |
| Additional Interest | Abbey Residential<br>PO Box 498067<br>Cincinnati, OH 45249 |
| Additional Interest Declaration email | [abbeystoneoak@abbeyresidential.com](mailto:abbeystoneoak@abbeyresidential.com) |

No contacts or visits on file yet.

## Anthony, The

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | ? |
| Additional Interest | ? |
| Additional Interest Declaration email | ? |

No contacts or visits on file yet.

## Boulevard at Sonterra, The

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | The Boulevard at Sonterra<br>210 E SONTERRA BLVD<br>San Antonio, TX 78258 |
| Additional Interest Declaration email | [boulevardleasing@shortmgmt.com](mailto:boulevardleasing@shortmgmt.com)<br>[boulevardleasing2@shortmgmt.com](mailto:boulevardleasing2@shortmgmt.com) |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Gloria | Yes | 210-496-4777 | [boulevardleasing@shortmgmt.com](mailto:boulevardleasing@shortmgmt.com) |
| Vessie | Yes | | [boulevardleasing2@shortmgmt.com](mailto:boulevardleasing2@shortmgmt.com) |

### Visits

| Date | Time | Who from here? | Who did we meet with? | Did we bring something? |
| --- | --- | --- | --- | --- |
| 01-29-2019 | | | | x4 Cupcakes |

## Creekstone

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | Creekstone Apartments - Greystar<br>P.O. Box 11509<br>Carrollton, TX 75011-5009 |
| Additional Interest Declaration email | [creekstonetx@greystar.com](mailto:creekstonetx@greystar.com) |

No contacts or visits on file yet.

## Crest Round Rock

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | Crest Round Rock Apartments |
| Additional Interest Declaration email | [roundrock@crestasset.com](mailto:roundrock@crestasset.com) |

No contacts or visits on file yet.

## Encore 281

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Full |
| Additional Interest | Encore 281 - Greystar<br>PO Box 115009<br>Carrollton, TX 75011-5009 |
| Additional Interest Declaration email | [encore281@greystar.com](mailto:encore281@greystar.com) |

No contacts or visits on file yet.

## Grandview Landmark

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | Grand View Landmark<br>15503 Vance Jackson Road<br>San Antonio, TX 78249 |
| Additional Interest Declaration email | [kmendiola@bandm.org](mailto:kmendiola@bandm.org) |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Krystle Mendiola | Yes | 210-877-6100 | [kmendiola@bandm.org](mailto:kmendiola@bandm.org) |

### Visits

| Date | Time | Who from here? | Who did we meet with? | Did we bring something? |
| --- | --- | --- | --- | --- |
| 01-29-2019 | | | | x4 Cupcakes |

## Hawthorne at Victoria

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Full |
| Additional Interest | Hawthorne at Victoria<br>2402 N Ben Wilson St<br>Victoria, TX 77901 |
| Additional Interest Declaration email | [hvictoria@hrpliving.com](mailto:hvictoria@hrpliving.com) |

No contacts or visits on file yet.

## Marquis at Stone Oak

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | WS Apartment Homes LLC<br>PO Box 115009<br>Carrollton, TX 75011 |
| Additional Interest Declaration email | |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Jennifer Valdez | Yes | 210-499-1200 | [jvaldez@cwsapartments.com](mailto:jvaldez@cwsapartments.com) |

No visits on file yet.

## Montecristo Apartments

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | |
| Additional Interest Declaration email | |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Claudia Herrera | Not Met | 210-877-5454 | [montecristoleasing@francispm.com](mailto:montecristoleasing@francispm.com) |
| Jocelyn Rivera | Met | 210-877-5454 | [montecristomanager@francispm.com](mailto:montecristomanager@francispm.com) |

No visits on file yet.

## Retreat at the Rim Apartments

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Full |
| Additional Interest | Retreat at the Rim Apartments - Greystar<br>P.O. Box 115009<br>Carrollton, TX 75011-5099 |
| Additional Interest Declaration email | [retreatattherim@greystar.com](mailto:retreatattherim@greystar.com) |

No contacts or visits on file yet.

## Savannah Oaks

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | 14614 Vance Jackson Road |
| Additional Interest Declaration email | [savannahoaksleasing@greystar.com](mailto:savannahoaksleasing@greystar.com) |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| | | 210-691-4614 | [savannahoaksleasing@greystar.com](mailto:savannahoaksleasing@greystar.com) |

### Visits

| Date | Time | Who from here? | Who did we meet with? | Did we bring something? |
| --- | --- | --- | --- | --- |
| 01-29-2019 | | | | x4 Cupcakes |

## Sendera Landmark

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | 19600 Vance Jackson Road |
| Additional Interest Declaration email | |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Floria (female) | | (210) 694-2200 | |

No visits on file yet.

## Toscana at Sonterra

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Full |
| Additional Interest | Toscana at Sonterra<br>19275 Stone Oak Pkwy<br>San Antonio, TX 78258 |
| Additional Interest Declaration email | [tos@westdale.com](mailto:tos@westdale.com) |

No contacts or visits on file yet.

## Tribute at the Rim

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Full |
| Additional Interest | Tribute at the Rim<br>Insurance Tracking<br>P.O. Box 979147<br>Miami, FL 33197 |
| Additional Interest Declaration email | [joe@tributeattherim.com](mailto:joe@tributeattherim.com)<br>[emery@tributeattherim.com](mailto:emery@tributeattherim.com)<br>[therim@tributeattherim.com](mailto:therim@tributeattherim.com) |

No contacts or visits on file yet.

## Vantage at Bulverde

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | ? |
| Additional Interest | Vantage at Bulverde<br>395 Harmony Hills Street<br>Spring Branch, TX 78070 |
| Additional Interest Declaration email | |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Tim Wright | Yes | 830-625-7850 | [vbvleasing1@foresightmanage.com](mailto:vbvleasing1@foresightmanage.com) |
| Ryan Horta (female) | No | ? | [vbvleasing2@foresightmanage.com](mailto:vbvleasing2@foresightmanage.com) |

No visits on file yet.

## Ventura Ridge

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $300,000 (maximum they'll allow?!?) |
| Sprinklers | Partial |
| Additional Interest | 5602 Presidio Parkway |
| Additional Interest Declaration email | [cynthia@venturaridge.com](mailto:cynthia@venturaridge.com) |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Cynthia Benavidez | No | 210-690-8800 | [cynthia@venturaridge.com](mailto:cynthia@venturaridge.com) |

### Visits

| Date | Time | Who from here? | Who did we meet with? | Did we bring something? |
| --- | --- | --- | --- | --- |
| 01-29-2019 | | | | x4 Tacos |

## Vineyard Springs

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Full |
| Additional Interest | Adara Communities Vineyard Springs<br>18200 Blanco Springs<br>San Antonio, TX 78258 |
| Additional Interest Declaration email | [vineyard@adaracommunities.com](mailto:vineyard@adaracommunities.com) |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| | | (210) 526-3959 | |

No visits on file yet.

## Viridian

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | Foster Rd GL LP<br>5415 N Foster Rd<br>San Antonio, TX 78244 |
| Additional Interest Declaration email | [viridian@nrpgroup.com](mailto:viridian@nrpgroup.com) |

No contacts or visits on file yet.

## West Oaks

| Detail | Value |
| --- | --- |
| Minimum liability | $100,000 |
| Recommended liability | $500,000 |
| Sprinklers | Partial |
| Additional Interest | 14838 Vance Jackson Road |
| Additional Interest Declaration email | [westooaks.pm@kettler.com](mailto:westooaks.pm@kettler.com) |

### Contacts

| Name | Met in person? | Direct Phone # | Direct Email |
| --- | --- | --- | --- |
| Raime Lyon | Met | 210-641-2883 | [westooaks.pm@kettler.com](mailto:westooaks.pm@kettler.com) |

### Visits

| Date | Time | Who from here? | Who did we meet with? | Did we bring something? |
| --- | --- | --- | --- | --- |
| 01-29-2019 | | | | x4 Cupcakes |
$md$,
    version = COALESCE(version, 0) + 1,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'processes'
  AND confluence_page_id = '1587675137'
  AND is_active = true;
