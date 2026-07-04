-- Playbook IA restructure (2026-07-03)
-- 1. Create Simple Mortgage FIT stub under 03 FIT Conversations
-- 2. Re-parent 6 Product Knowledge roots under matching Simple FITs
-- 3. Soft-delete Checklists + Product Knowledge wrapper rows
-- Frontend Playbook.jsx will additionally filter Tech Support to a new TechSupport module.
-- tree_root values preserved for label continuity (playbook_tree_root_check unchanged).

-- Step 1: Simple Mortgage FIT stub
INSERT INTO public.playbook (
  agency_id, title, content, content_format,
  confluence_page_id, parent_page_id, tree_root,
  version, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Simple Mortgage FIT',
  '<p><em>Placeholder — mortgage conversation content to be added. Mortgage Knowledge reference is nested below.</em></p>',
  'html',
  'bcc-native-simple-mortgage-fit',
  '2124251137',
  'Checklists',
  1,
  true
);

-- Step 2: Re-parent Product Knowledge roots to matching FIT pages
UPDATE public.playbook SET parent_page_id = '2583035905'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '893550593';
UPDATE public.playbook SET parent_page_id = '2474475654'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '843415603';
UPDATE public.playbook SET parent_page_id = '2716762128'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '354844680';
UPDATE public.playbook SET parent_page_id = '1530134531'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '1457225729';
UPDATE public.playbook SET parent_page_id = '1702035459'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '878084452';
UPDATE public.playbook SET parent_page_id = 'bcc-native-simple-mortgage-fit'
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '816676877';

-- Step 3: Soft-delete wrapper containers
UPDATE public.playbook SET is_active = false, archived_at = NOW()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '1726480570';
UPDATE public.playbook SET is_active = false, archived_at = NOW()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND confluence_page_id = '812384316';
