-- Peter 2026-09-14: the item's own words stay AND the shared fragment shows
-- underneath. Restores the missing_phone help text I wrongly cleared, and does
-- the same excerpt treatment for the Quotes Missing Data list.

UPDATE public.checklist_items
SET help_text = $h$Opportunities and customers with no usable phone number.

Set the list up on the *Lead Process page in ECRM. Work it every day. All cleared by end of day.$h$,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND item_key = 'missing_phone';

INSERT INTO public.manuals
  (agency_id, manual_type, title, content, content_format, confluence_page_id, is_active)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'excerpt',
  'Quotes Missing Data',
  $h$**Title:** #Quotes Missing Data

1. Restrict records on this list with filter 1-3
2. Move records onto this list with filters 4-10
3. Move records off this list by adding the missing data

<table><tbody><tr><td><strong>1</strong></td><td>Stage</td><td>equals</td><td>App Submitted, Closed Won</td></tr><tr><td><strong>2</strong></td><td>Status</td><td>equals</td><td>Quote Discussed</td></tr><tr><td><strong>3</strong></td><td>Last Modified Date</td><td>greater or equal</td><td>LAST 13 WEEKS</td></tr><tr><td><strong>4</strong></td><td>Relationship Type</td><td>equals</td><td></td></tr><tr><td><strong>5</strong></td><td>Marketing Source</td><td>equals</td><td></td></tr><tr><td><strong>6</strong></td><td>Marketing Source</td><td>equals</td><td>Did Not Ask, Marketing, Other, Outbound Calling</td></tr><tr><td><strong>7</strong></td><td>Total Premium</td><td>less or equal</td><td>0</td></tr><tr><td><strong>8</strong></td><td>Current Insurer Name</td><td>equals</td><td></td></tr><tr><td><strong>9</strong></td><td>Current Premium</td><td>less or equal</td><td>0</td></tr><tr><td><strong>10</strong></td><td>X-Date</td><td>equals</td><td></td></tr></tbody></table>

**Filter Logic:** (1 OR 2) AND 3 AND (4 OR 5 OR 6 OR 7 OR 8 OR 9 OR 10)

### Fields to Display:

1. Last Modified Date *(sort by most recent)*
2. Opportunity Name
3. Stage
4. Status
5. Relationship Type
6. Marketing Source
7. Total Premium
8. Current Insurer Name
9. Current Premium
10. X-Date
11. Probability (%)$h$,
  'markdown',
  'newtworks-native-quotes-missing-data',
  true
)
ON CONFLICT DO NOTHING;

UPDATE public.manuals
SET content = replace(
      content,
      $h$<summary>#Quotes Missing Data</summary>

**Title:** #Quotes Missing Data

1. Restrict records on this list with filter 1-3
2. Move records onto this list with filters 4-10
3. Move records off this list by adding the missing data

<table><tbody><tr><td><strong>1</strong></td><td>Stage</td><td>equals</td><td>App Submitted, Closed Won</td></tr><tr><td><strong>2</strong></td><td>Status</td><td>equals</td><td>Quote Discussed</td></tr><tr><td><strong>3</strong></td><td>Last Modified Date</td><td>greater or equal</td><td>LAST 13 WEEKS</td></tr><tr><td><strong>4</strong></td><td>Relationship Type</td><td>equals</td><td></td></tr><tr><td><strong>5</strong></td><td>Marketing Source</td><td>equals</td><td></td></tr><tr><td><strong>6</strong></td><td>Marketing Source</td><td>equals</td><td>Did Not Ask, Marketing, Other, Outbound Calling</td></tr><tr><td><strong>7</strong></td><td>Total Premium</td><td>less or equal</td><td>0</td></tr><tr><td><strong>8</strong></td><td>Current Insurer Name</td><td>equals</td><td></td></tr><tr><td><strong>9</strong></td><td>Current Premium</td><td>less or equal</td><td>0</td></tr><tr><td><strong>10</strong></td><td>X-Date</td><td>equals</td><td></td></tr></tbody></table>



**Filter Logic:** (1 OR 2) AND 3 AND (4 OR 5 OR 6 OR 7 OR 8 OR 9 OR 10)

### Fields to Display:

1. Last Modified Date *(sort by most recent)*
2. Opportunity Name
3. Stage
4. Status
5. Relationship Type
6. Marketing Source
7. Total Premium
8. Current Insurer Name
9. Current Premium
10. X-Date
11. Probability (%)

</details>$h$,
      $h$<summary>#Quotes Missing Data</summary>

*[Embedded excerpt from: Quotes Missing Data]*

</details>$h$
    ),
    version = COALESCE(version, 0) + 1,
    updated_at = NOW()
WHERE id = 'a8ab7ed7-6ba8-4fea-8aaf-d94334f1f38d';

UPDATE public.checklist_items
SET help_excerpt_id = (
      SELECT m.id FROM public.manuals m
      WHERE m.agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND m.manual_type = 'excerpt' AND m.title = 'Quotes Missing Data'
      LIMIT 1
    ),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND item_key = 'missing_data';