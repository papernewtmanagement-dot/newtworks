-- Techbook IA cleanup 2026-07-03:
--  1. Soft-delete the "Tech Support" parent playbook row (redundant now that
--     Techbook is its own top-level nav — the intermediate node just wraps
--     the same children the nav already scopes to).
--  2. Soft-delete "Racing Snail" (deprecated).
--  3. Promote the remaining 10 direct children of the Tech Support parent to
--     top-level of the Techbook tree by setting parent_page_id = NULL
--     (Playbook.jsx buildTree treats no-parent rows as roots).
--     Systems Setup keeps its subtree (Desk Checklist + Office — Systems
--     Setup, and Office's own children Team by the Minute + Voicemail) intact
--     because those rows point to their own parents (901382160, 1283129345),
--     not to 346751115.

-- 1 + 2: soft-delete Tech Support parent + Racing Snail
UPDATE public.playbook
SET is_active = false,
    archived_at = NOW(),
    notes = COALESCE(notes || E'\n', '') || '[2026-07-03] Retired during Techbook flatten — parent node no longer needed; children promoted to top level.'
WHERE id = '0f78194d-ff2d-4bfd-92c0-68bb55fc73a2';

UPDATE public.playbook
SET is_active = false,
    archived_at = NOW(),
    notes = COALESCE(notes || E'\n', '') || '[2026-07-03] Removed from Techbook per Peter.'
WHERE id = 'b946fbf1-2293-4cd5-8dc0-30ba32511181';

-- 3: promote the remaining direct children of Tech Support (346751115) to top level
UPDATE public.playbook
SET parent_page_id = NULL
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND tree_root = 'Tech Support'
  AND parent_page_id = '346751115'
  AND is_active = true
  AND id NOT IN (
    '0f78194d-ff2d-4bfd-92c0-68bb55fc73a2',  -- Tech Support parent (already handled above)
    'b946fbf1-2293-4cd5-8dc0-30ba32511181'   -- Racing Snail (already handled above)
  );
