-- Peter 2026-09-14: label the four cleanup lists on the *Lead Process page.
-- Sits above Missing Phone and covers it, Quotes Missing Data, Closed Opps to
-- Reopen and Do Not Solicit — everything below the contact cadence lists.
UPDATE public.manuals
SET content = replace(
      content,
      '<details>
<summary>#Missing Phone - True People</summary>',
      '**Daily Cleanup:**

<details>
<summary>#Missing Phone - True People</summary>'
    ),
    version = COALESCE(version, 0) + 1,
    updated_at = NOW()
WHERE id = 'a8ab7ed7-6ba8-4fea-8aaf-d94334f1f38d';