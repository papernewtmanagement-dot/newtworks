-- Move GAINSCO Texas Fast Facts + SF Texas Personal Auto Program Rule Manual
-- from Playbook top-level (parent NULL) into Simple Auto FIT (confluence_page_id '2583035905').
-- Both keep tree_root='Product Knowledge' — the Playbook module loads both tree_roots
-- and buildTree relies on parent_page_id, so this reparents them into the Simple Auto FIT
-- subtree alongside Auto Knowledge.

UPDATE public.playbook
SET parent_page_id = '2583035905',
    updated_at     = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND confluence_page_id IN (
    'bcc-native-gainsco-tx-fast-facts-2026-07-02',
    'bcc-native-tx-mga-auto-rules-2026-07-02'
  );
