-- Reception / Retention Tasks / Retention Appointments subpages must not carry
-- major (banded H2) headers of their own. These pages get pulled into the parent
-- checklist pages as fragments inside collapsible sections, where a full-width
-- banner heading reads wrong. Headers arriving from an included excerpt fragment
-- are untouched -- they live in their own excerpt rows.
-- H2 -> H3 everywhere. On the one page that already nests H3 under H2 (Referrals),
-- H3 -> H4 first so the hierarchy is preserved rather than flattened.

WITH RECURSIVE tree AS (
  SELECT id, confluence_page_id
  FROM manuals
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND manual_type = 'processes'
    AND parent_page_id IN ('1746010123', '1726546221', '1747025922')
  UNION ALL
  SELECT m.id, m.confluence_page_id
  FROM manuals m
  JOIN tree t ON m.parent_page_id = t.confluence_page_id
  WHERE m.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND m.manual_type = 'processes'
),
targets AS (SELECT DISTINCT id FROM tree)
UPDATE manuals m
SET content = regexp_replace(
      CASE
        WHEN m.content ~ '(?n)^###[ \t]'
          THEN regexp_replace(m.content, '^###[ \t]', '#### ', 'gm')
        ELSE m.content
      END,
      '^##[ \t]', '### ', 'gm'),
    updated_at = NOW()
FROM targets t
WHERE m.id = t.id
  AND m.is_active
  AND m.content ~ '(?n)^##[ \t]';
