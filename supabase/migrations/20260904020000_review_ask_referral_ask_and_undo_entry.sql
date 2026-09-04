-- Review Ask and Referral Ask tracked at $0 like Pivot (the outcome pays:
-- Google Review $5, Referral Sold $10). rp_undo_entry(result): voids every
-- row an entry created through the same void functions the Remove buttons
-- use, and gives back saves a canceled row took away.
-- Live definition: migration review_ask_referral_ask_and_undo_entry in Supabase.
INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, requires_note, sort_order, is_active, description) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'review_ask', 'Review Ask', 0.00, 'logged', false, 6, true,
  'You asked the customer for a Google review. Tracking only. The review itself pays when it posts.'),
 ('126794dd-25ff-47d2-a436-724499733365', 'referral_ask', 'Referral Ask', 0.00, 'logged', false, 7, true,
  'You asked the customer who else they know that should hear from us. Tracking only. Referral Sold pays when the referral becomes a household.')
ON CONFLICT (agency_id, activity_key) DO UPDATE SET label = EXCLUDED.label, points = EXCLUDED.points, sort_order = EXCLUDED.sort_order, description = EXCLUDED.description, is_active = true, updated_at = now();
