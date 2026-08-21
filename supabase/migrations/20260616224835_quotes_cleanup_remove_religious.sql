-- Remove explicit Bible verses and explicitly-religious-content quotes from both pools
DELETE FROM public.health_quotes
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND (
    attribution ILIKE '%Psalm%'
    OR attribution ILIKE '%Proverbs%'
    OR attribution ILIKE '%Colossians%'
    OR attribution ILIKE '%Philippians%'
    OR attribution ILIKE '%Ecclesiastes%'
    OR attribution ILIKE '%Joshua%'
    OR attribution ILIKE '%Corinthians%'
    OR attribution ILIKE '%Eric Liddell%'
  );

-- Replenish morning_motivation pool (Peter directed: no explicit Bible/religious references)
INSERT INTO public.health_quotes (agency_id, quote_text, attribution, flavor, pool) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'The best preparation for tomorrow is doing your best today.', 'H. Jackson Brown Jr.', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'You will never have this day again. Make it count.', NULL, 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Success isn''t owned. It''s leased. And rent is due every day.', 'J.J. Watt', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Either you run the day or the day runs you.', 'Jim Rohn', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'It always seems impossible until it''s done.', 'Nelson Mandela', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Success is the sum of small efforts repeated day in and day out.', 'Robert Collier', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Quality is not an act, it is a habit.', 'Aristotle', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Energy and persistence conquer all things.', 'Benjamin Franklin', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'What you do every day matters more than what you do once in a while.', 'Gretchen Rubin', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Excellence is not a skill. It''s an attitude.', 'Ralph Marston', 'inspiring', 'morning_motivation');

-- Replenish health_eve pool (replacing Liddell + 1 Cor with secular fitness wisdom)
INSERT INTO public.health_quotes (agency_id, quote_text, attribution, flavor, pool) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'We do not stop exercising because we grow old. We grow old because we stop exercising.', 'Kenneth Cooper', 'inspiring', 'health_eve'),
  ('126794dd-25ff-47d2-a436-724499733365', 'The only person you should try to be better than is the person you were yesterday.', NULL, 'inspiring', 'health_eve'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Movement is medicine.', NULL, 'inspiring', 'health_eve');
