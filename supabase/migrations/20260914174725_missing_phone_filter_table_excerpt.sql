-- Peter 2026-09-14: the Missing Phone filter settings on the Lead Process page
-- become a real table, and the whole section moves into one shared excerpt that
-- the page and the "Missing Phone list cleared" checklist item both pull from.

INSERT INTO public.manuals
  (agency_id, manual_type, title, content, content_format, confluence_page_id, is_active)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'excerpt',
  'Missing Phone - True People',
  '**Title:** \*Missing Phone - True People

<table><tbody><tr><td><strong>1</strong></td><td>Stage</td><td>equals</td><td>New, Not Now - Follow Up</td></tr><tr><td><strong>2</strong></td><td>Opportunity Mobile Phone</td><td>equals</td><td></td></tr><tr><td><strong>3</strong></td><td>Opportunity Home Phone</td><td>equals</td><td></td></tr></tbody></table>

**No Unique Filter Logic**

Add “Created Date” to Fields to Display and sort by the most recent Created Date',
  'markdown',
  'newtworks-native-missing-phone-true-people',
  true
)
ON CONFLICT DO NOTHING;

UPDATE public.manuals
SET content = replace(
      content,
      '<summary>#Missing Phone - True People</summary>

**Title:** \*Missing Phone - True People

**1**

Stage

equals

New, Not Now - Follow Up

**2**

Opportunity Mobile Phone

equals

**3**

Opportunity Home Phone

equals

**No Unique Filter Logic**

Add “Created Date” to Fields to Display and sort by the most recent Created Date

</details>',
      '<summary>#Missing Phone - True People</summary>

*[Embedded excerpt from: Missing Phone - True People]*

</details>'
    ),
    version = COALESCE(version, 0) + 1,
    updated_at = NOW()
WHERE id = 'a8ab7ed7-6ba8-4fea-8aaf-d94334f1f38d';

UPDATE public.checklist_items
SET help_excerpt_id = (
      SELECT m.id FROM public.manuals m
      WHERE m.agency_id = '126794dd-25ff-47d2-a436-724499733365'
        AND m.manual_type = 'excerpt' AND m.title = 'Missing Phone - True People'
      LIMIT 1
    ),
    help_text = NULL,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND item_key = 'missing_phone';