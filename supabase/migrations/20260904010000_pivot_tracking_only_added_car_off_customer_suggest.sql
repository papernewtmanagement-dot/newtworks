-- Pivot tracked at $0 (attempt has no retention value of its own; the outcome
-- pays via Policy Review / Multiline). Added Car off the activity list: it is
-- commissioned like any other sale. rp_customer_suggest(prefix): up to eight
-- customer names on file matching what was typed, for the entry page.
-- Live definition: migration pivot_tracking_only_added_car_off_customer_suggest in Supabase.
INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, requires_note, sort_order, is_active, description)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'pivot', 'Pivot', 0.00, 'logged', false, 5, true,
        'You steered the conversation to a product the household does not have with us. Tracking only. The retention value shows up when it becomes a Policy Review or a Multiline, and those pay on their own.')
ON CONFLICT (agency_id, activity_key) DO UPDATE SET label = EXCLUDED.label, points = EXCLUDED.points, sort_order = EXCLUDED.sort_order, description = EXCLUDED.description, is_active = true, updated_at = now();
UPDATE public.retention_point_values SET is_active = false, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task_added_car';
