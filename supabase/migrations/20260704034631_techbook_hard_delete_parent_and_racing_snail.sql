-- Hard-delete the two rows previously soft-archived in
-- techbook_flatten_and_remove_racing_snail. Peter clarified: he wanted
-- them GONE, not archived. No FK refs to playbook.id (verified), and their
-- 10 former children already have parent_page_id = NULL from the prior
-- migration, so no orphans.

DELETE FROM public.playbook
WHERE id IN (
  '0f78194d-ff2d-4bfd-92c0-68bb55fc73a2',  -- Tech Support parent
  'b946fbf1-2293-4cd5-8dc0-30ba32511181'   -- Racing Snail
);
