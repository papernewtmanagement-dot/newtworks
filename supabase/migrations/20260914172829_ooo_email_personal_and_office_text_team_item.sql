-- Peter 2026-09-14: the personal out-of-office item is about the person's own
-- email. The out-of-office text is set once for the whole office, so it becomes
-- a team item.

UPDATE public.checklist_items
SET title = 'Out-of-office email set',
    help_text = 'Turn your out-of-office email reply on when you leave for the week, and off when you are back.

This is your own mailbox. The office texting line is a separate team item.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND item_key = 'ooo' AND scope = 'personal';

INSERT INTO public.checklist_items
  (agency_id, item_key, title, scope, sort_order, effective_from, effective_to, help_text)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'ooo_text_office',
   'Office out-of-office text set', 'team', 150, DATE '2026-09-14', NULL,
   'One setting for the whole office, not per person. Turn the out-of-office text reply on when the office closes for the day, and off when it opens.

Whoever closes the day owns it.')
ON CONFLICT DO NOTHING;