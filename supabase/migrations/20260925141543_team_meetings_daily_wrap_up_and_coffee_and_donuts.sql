-- The two new daily team meetings (Peter 2026-09-25). Same roster, same
-- automatic add and remove as the Daily Kickoff, no Meet or Teams link, a link
-- to the daily checklist. Weekdays like the kickoff, first meeting Monday
-- 2026-09-28. calendar_event_id starts empty, so the next sync creates each
-- series and invites the team.
INSERT INTO public.agency_huddle_config
  (agency_id, meeting_key, event_title, start_time_local, duration_regular_min, duration_fri_min,
   days_of_week, calendar_id, event_first_date, event_description, event_location, calendar_needs_sync)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'coffee_and_donuts',
   'Coffee and Donuts!!!!!!! (Formerly Tea & Crumpets when we were under British rule)',
   '12:30', 30, 30, ARRAY['MO','TU','WE','TH','FR'], 'paper.newt.management@gmail.com', '2026-09-28',
   'Daily checklist: https://newtworks.vercel.app/?tab=checklist

A midday break to step away and reset:
• Midday check-in: how the day is going so far
• Just hang out
• Newbie questions: ask anything, nothing is too basic
• Required conversation reviews',
   NULL, true),
  ('126794dd-25ff-47d2-a436-724499733365', 'daily_wrap_up',
   'Daily Wrap-up',
   '17:00', 30, 30, ARRAY['MO','TU','WE','TH','FR'], 'paper.newt.management@gmail.com', '2026-09-28',
   'Daily checklist: https://newtworks.vercel.app/?tab=checklist

Closing out the day together:
• Go over the daily checklist and close out anything still open
• Talk about how the day went
• Celebrate the wins, big and small
• Talk through any obstacles we ran into',
   NULL, true)
ON CONFLICT (agency_id, meeting_key) DO NOTHING;
