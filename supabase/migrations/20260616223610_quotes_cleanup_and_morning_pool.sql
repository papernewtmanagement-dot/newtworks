-- 1. Add pool column to support multiple quote contexts; video_url for future
ALTER TABLE public.health_quotes ADD COLUMN IF NOT EXISTS pool text NOT NULL DEFAULT 'health_eve';
ALTER TABLE public.health_quotes ADD COLUMN IF NOT EXISTS video_url text;
CREATE INDEX IF NOT EXISTS health_quotes_pool_idx ON public.health_quotes (agency_id, pool, is_active);

-- 2. Remove non-Biblical religious sources per agency rule
DELETE FROM public.health_quotes
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND (attribution ILIKE '%Gandhi%' OR attribution ILIKE '%Muhammad Ali%' OR attribution ILIKE 'Ali');

-- 3. Replace the two removed slots with Biblically-aligned health quotes
INSERT INTO public.health_quotes (agency_id, quote_text, attribution, flavor, pool) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'When I run, I feel His pleasure.', 'Eric Liddell', 'inspiring', 'health_eve'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Do you not know that your bodies are temples of the Holy Spirit? Honor God with your bodies.', '1 Corinthians 6:19-20', 'inspiring', 'health_eve'),
  ('126794dd-25ff-47d2-a436-724499733365', 'The harder you work, the harder it is to surrender.', 'Vince Lombardi', 'inspiring', 'health_eve');

-- 4. Seed the morning_motivation pool — hit-the-day energy
INSERT INTO public.health_quotes (agency_id, quote_text, attribution, flavor, pool) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'This is the day the Lord has made; let us rejoice and be glad in it.', 'Psalm 118:24', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Whatever you do, work at it with all your heart, as working for the Lord, not for human masters.', 'Colossians 3:23', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Commit to the Lord whatever you do, and he will establish your plans.', 'Proverbs 16:3', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'I can do all things through him who strengthens me.', 'Philippians 4:13', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Whatever your hand finds to do, do it with all your might.', 'Ecclesiastes 9:10', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Diligent hands will rule, but laziness ends in forced labor.', 'Proverbs 12:24', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Be strong and courageous. Do not be afraid; the Lord your God will be with you wherever you go.', 'Joshua 1:9', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'The plans of the diligent lead to profit as surely as haste leads to poverty.', 'Proverbs 21:5', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Discipline equals freedom.', 'Jocko Willink', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Discipline is the bridge between goals and accomplishment.', 'Jim Rohn', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'The harder you work, the harder it is to surrender.', 'Vince Lombardi', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Hard work beats talent when talent doesn''t work hard.', 'Tim Tebow', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'The separation is in the preparation.', 'Russell Wilson', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Do not let what you cannot do interfere with what you can do.', 'John Wooden', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'It''s not always going to be easy, but the things worth doing rarely are.', 'Tony Dungy', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Hardships often prepare ordinary people for an extraordinary destiny.', 'C.S. Lewis', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Don''t watch the clock; do what it does. Keep going.', 'Sam Levenson', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Whether you think you can or you think you can''t, you''re right.', 'Henry Ford', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Believe you can and you''re halfway there.', 'Theodore Roosevelt', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'The two most important days in your life are the day you are born and the day you find out why.', 'Mark Twain', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Start where you are. Use what you have. Do what you can.', 'Arthur Ashe', 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Show up. Be the first one in and the last one out. The rest takes care of itself.', NULL, 'inspiring', 'morning_motivation'),
  ('126794dd-25ff-47d2-a436-724499733365', 'Pressure is a privilege.', 'Billie Jean King', 'inspiring', 'morning_motivation');
