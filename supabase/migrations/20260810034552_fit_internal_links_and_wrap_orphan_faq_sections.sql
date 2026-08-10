-- Same-class sweep off the Simple Auto FIT pass:
--  (1) FIT-conversation cross-links still pointing at Confluence -> internal /processes/<confluence_page_id>
--  (2) "Knowledge & FAQ" blocks left as bare text instead of a collapsible section

-- (1) internal links
UPDATE public.manuals SET
  content = replace(content,
    '[Simple Valuables FIT](https://pjsagency.atlassian.net/wiki/pages/resumedraft.action?draftId=1975844866)',
    '[Simple Valuables FIT](/processes/1975844866)'),
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND title = 'Contents Bridge the Gap';

UPDATE public.manuals SET
  content = replace(content,
    '[Simple Life FIT](https://pjsagency.atlassian.net/wiki/x/AwBzZQ)',
    '[Simple Life FIT](/processes/1702035459)'),
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND title IN ('Auto Death Benefit Bridge the Gap', 'Simple Home FIT');

UPDATE public.manuals SET
  content = replace(
              replace(content,
                '[Simple HI FIT](https://pjsagency.atlassian.net/wiki/x/BIBFmg)',
                '[Simple HI FIT](/processes/2588246020)'),
              '[Simple DI FIT](https://pjsagency.atlassian.net/wiki/x/AYBNmg)',
              '[Simple DI FIT](/processes/2588770305)'),
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND title = 'Simple Home FIT';

-- (2) wrap the two orphaned FAQ blocks so they collapse inside their own section,
--     matching every other Bridge the Gap excerpt
UPDATE public.manuals SET
  content = replace(content,
              E'Knowledge & FAQ\n> **\u2139\uFE0F INFO**',
              E'<details>\n<summary>Knowledge &amp; FAQ</summary>\n\n> **\u2139\uFE0F INFO**')
            || E'\n\n</details>',
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND title IN ('DI Bridge the Gap', 'HI Bridge the Gap')
  AND content ~ '(^|\n)Knowledge & FAQ(\n|$)';
