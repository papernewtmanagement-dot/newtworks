-- Peter directive 2026-07-21: place the dividing line in the processes manual.
-- Above the line (team-visible): Daily Kickoff, Daily Wrap-up
-- Below the line (admin-only WIP): FIT Conversations, Reception, Retention Tasks, Retention Appointments
--
-- Two edits:
--  1. Move Daily Wrap-up from sort_order=70 (last) to sort_order=20 (second),
--     so it sits right after Daily Kickoff and above the WIP block.
--  2. Set divider_after=true on Daily Wrap-up so it becomes the boundary row.
--
-- Frontend Manual.jsx will read divider_after and hide below-divider roots +
-- their descendants for non-admin users.

UPDATE public.manuals
SET sort_order = 20,
    divider_after = true,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND manual_type = 'processes'
  AND confluence_page_id = '1590689841'  -- Daily Wrap-up
  AND is_active = true;
