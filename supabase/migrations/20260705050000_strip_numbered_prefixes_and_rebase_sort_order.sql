-- Migration: strip_numbered_prefixes_and_rebase_sort_order
-- Applied via Supabase MCP on 2026-07-05. Mirrored to repo per GitHub-mirror rule.
-- ─────────────────────────────────────────────────────────────
-- Add sort_order column to playbook + admin_pages (handbook already had it).
-- Rebase all top-level sort_order values to positive integers preserving current
-- display order. Strip "01 ", "02 " … prefixes from titles in Handbook + Processes.
-- In Processes, move Team Huddle to the top.
-- ─────────────────────────────────────────────────────────────

ALTER TABLE public.playbook     ADD COLUMN IF NOT EXISTS sort_order INTEGER;
ALTER TABLE public.admin_pages  ADD COLUMN IF NOT EXISTS sort_order INTEGER;

-- HANDBOOK: rebase top-level to positive integers, strip 01-04 prefixes
UPDATE handbook SET sort_order = 10  WHERE id = '0b19316c-5307-42e6-859c-ca432d8fe978';
UPDATE handbook SET sort_order = 20, title = 'Your Path Through the Agency'       WHERE id = '6e1cc53f-b2e6-473a-9adf-85f8e705589b';
UPDATE handbook SET sort_order = 30, title = 'Hours, Location & Time Off'         WHERE id = '33db0267-1c0f-4602-afb7-eb1f5e7a5bf9';
UPDATE handbook SET sort_order = 40, title = 'How You Get Paid'                   WHERE id = '3482bf9c-58c9-4cee-a31d-15335a904269';
UPDATE handbook SET sort_order = 50, title = 'Winning, Learning & Getting Better' WHERE id = '0496c2de-fb44-41a5-8a3b-3542535e92a0';
UPDATE handbook SET sort_order = 60  WHERE id = '4f940de5-0c5a-4f4c-a318-478830477692';
UPDATE handbook SET sort_order = 70  WHERE id = '65c7529e-4de0-404f-af26-c67c8bea7cfe';
UPDATE handbook SET sort_order = 80  WHERE id = '9f268028-a3c1-452b-82eb-becea7525a98';
UPDATE handbook SET sort_order = 90  WHERE id = 'afe84c6c-d441-4249-a0f3-52fafb7b3fc9';
UPDATE handbook SET sort_order = 100 WHERE id = 'fff6cee6-f1d8-42c2-a453-eeb15c832d3a';
UPDATE handbook SET sort_order = 110 WHERE id = '68da2652-adc5-4d1b-92ae-5c08a284afc2';
UPDATE handbook SET sort_order = 120 WHERE id = '532f8c4b-0b1e-4a8c-8338-58838f1155cd';
UPDATE handbook SET sort_order = 130 WHERE id = 'a3aa61c7-3c81-404c-80de-8f85944f18b1';

-- PROCESSES: seed top-level, Team Huddle first
UPDATE playbook SET sort_order = 10  WHERE id = 'a80fdcc1-1928-488a-bb5d-0cf62a9524ec';
UPDATE playbook SET sort_order = 20, title = 'Reception'              WHERE id = 'a5d5e94a-7957-4dcd-aca0-7098d058b5bc';
UPDATE playbook SET sort_order = 30, title = 'Retention Appointments' WHERE id = '44ae4147-389e-4dd5-82d0-3df20f8cb6cb';
UPDATE playbook SET sort_order = 40, title = 'FIT Conversations'      WHERE id = 'c129f8b1-c128-4699-84b4-301cf9df0946';
UPDATE playbook SET sort_order = 50, title = 'Daily Checklist'        WHERE id = 'e427ccf0-1907-4b6a-8e7a-3e9376f3ac7b';
UPDATE playbook SET sort_order = 60, title = 'Retention Tasks'        WHERE id = '73db6711-3798-43b8-b1d0-6b889ceb5c1b';
UPDATE playbook SET sort_order = 70  WHERE id = 'f998ea64-f5c7-4242-a30d-e65428f84205';

-- Training's numbered children
UPDATE playbook SET sort_order = 10, title = 'Admin Setup'               WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true AND parent_page_id = '2716532737' AND title = '01 Admin Setup';
UPDATE playbook SET sort_order = 20, title = 'Tech Setup'                WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true AND parent_page_id = '2716532737' AND title = '02 Tech Setup';
UPDATE playbook SET sort_order = 30, title = 'New Reception Setup'       WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true AND parent_page_id = '2716532737' AND title = '03 New Reception Setup';
UPDATE playbook SET sort_order = 40, title = 'New Account Manager Setup' WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true AND parent_page_id = '2716532737' AND title = '04 New Account Manager Setup';
UPDATE playbook SET sort_order = 50 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true AND parent_page_id = '2716532737' AND title = 'Desk Checklist';
UPDATE playbook SET sort_order = 60 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true AND parent_page_id = '2716532737' AND title = 'Office - Systems Setup, Tech Support';
UPDATE playbook SET sort_order = 70 WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true AND parent_page_id = '2716532737' AND title = 'Paid Training Programs';

-- ADMIN: seed top-level in current alphabetical order, strip the one numbered prefix
UPDATE admin_pages SET sort_order = 10  WHERE id = '11d41f8c-7396-4099-a6f6-4601d0dea843';
UPDATE admin_pages SET sort_order = 20, title = 'New P&C Setup - Training, Checklists old' WHERE id = '4d770345-e6a1-46af-8d5f-e6c3c31d3608';
UPDATE admin_pages SET sort_order = 30  WHERE id = 'a9551e1a-0894-4003-9d11-633a1abde232';
UPDATE admin_pages SET sort_order = 40  WHERE id = '1ccb3628-d004-429e-9c48-3b22a85c8d09';
UPDATE admin_pages SET sort_order = 50  WHERE id = 'a5c526f7-469a-4d08-8c16-946cd073aba8';
UPDATE admin_pages SET sort_order = 60  WHERE id = '67d6c2a0-754a-49de-9cd5-764fe52bd5b0';
UPDATE admin_pages SET sort_order = 70  WHERE id = 'fb1b837c-a6af-4702-b04d-71760e77817e';
UPDATE admin_pages SET sort_order = 80  WHERE id = '552ece14-fa47-4139-9c95-8acc98ae9c74';
UPDATE admin_pages SET sort_order = 90  WHERE id = '2f6a5643-4b1e-4ba4-8d9a-274c92e35642';
UPDATE admin_pages SET sort_order = 100 WHERE id = '3712da0b-68d7-4ea9-9b76-1833717a0c5b';
UPDATE admin_pages SET sort_order = 110 WHERE id = '4dd80fac-ef41-4c3d-ba81-5f87335c5278';
UPDATE admin_pages SET sort_order = 120 WHERE id = 'c6975667-fd7d-457f-8a79-714b1a9e4775';
UPDATE admin_pages SET sort_order = 130 WHERE id = '1028ffb0-ec9a-4164-90e9-ccf75af10526';
UPDATE admin_pages SET sort_order = 140 WHERE id = 'd2ed2aac-1621-4ce2-860c-095ecfc15ade';
UPDATE admin_pages SET sort_order = 150 WHERE id = '8710c01b-4ce2-4fa0-bc64-0e535859d89c';
UPDATE admin_pages SET sort_order = 160 WHERE id = 'bfa720a6-cc2f-4f51-ae7b-4002d01b6ea7';
UPDATE admin_pages SET sort_order = 170 WHERE id = '26ea1626-2692-4256-bde8-376116a08a64';
UPDATE admin_pages SET sort_order = 180 WHERE id = '6398d926-a735-4119-a8a4-2154f5c471b7';
UPDATE admin_pages SET sort_order = 190 WHERE id = '14864204-7121-4f76-8b48-4a39b605204b';
