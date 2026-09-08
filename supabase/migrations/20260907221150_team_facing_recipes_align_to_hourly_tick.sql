-- The runner now ticks at :59. A recipe scheduled anywhere in hour H fires at H:59.
-- Team-facing sequences (reminder, tag missing, compile) are rewritten to the minute
-- they will actually fire, so wall-clock times stay close to the original design and
-- the reminder-to-tag gap stays a full hour instead of collapsing to zero.

UPDATE public.automation_recipes SET cron_expression = v.expr, updated_at = NOW()
FROM (VALUES
  ('Team Checkin — Morning Reminder',   '59 7 * * 1-5'),   -- was 8:25, now 7:59 (before the 8:30 meeting)
  ('Team Checkin — Midday Reminder',    '59 11 * * 1-5'),  -- was 12:00, now 11:59
  ('Team Checkin — Midday Tag Missing', '58 12 * * 1-5'),  -- was 12:30, now 12:59 (first)
  ('Team Checkin — Midday Compile',     '59 12 * * 1-5'),  -- was 13:00, now 12:59 (second)
  ('Team Checkin — EOD Reminder',       '59 16 * * 1-5'),  -- was 17:00, now 16:59
  ('Team Checkin — EOD Tag Missing',    '58 17 * * 1-5'),  -- was 17:30, now 17:59 (first)
  ('Team Checkin — EOD Compile',        '59 17 * * 1-5'),  -- was 18:00, now 17:59 (second)
  ('Health Checkin — Weekday Prompt',   '59 18 * * 1-5'),  -- was 19:00, now 18:59
  ('Health Checkin — Weekday Compile',  '59 19 * * 1-5'),  -- was 20:00, now 19:59
  ('Health Checkin — Saturday Prompt',  '59 20 * * 6'),    -- was 21:00, now 20:59
  ('Health Checkin — Saturday Compile', '59 21 * * 6')     -- was 22:00, now 21:59
) AS v(name, expr)
WHERE automation_recipes.recipe_name = v.name
  AND automation_recipes.agency_id = '126794dd-25ff-47d2-a436-724499733365';
