-- Peter 2026-09-22: Becca's Dinner Dishes is a bigger job than 20 minutes.
-- Dinner for seven: pots and pans washed by hand, dishwasher loaded, disposal run, sink and counters cleared: about 30 minutes.
UPDATE public.family_chores SET est_minutes = 30, pay = public.family_minutes_pay(30, agency_id)
 WHERE id = '9e6db89d-743f-480a-b706-33288f414eb7';
-- Open weeks take the new price.
UPDATE public.family_chore_log l SET amount = public.family_log_amount(l.chore_id, l.status, l.occurrence_date), updated_at = now()
 WHERE l.chore_id = '9e6db89d-743f-480a-b706-33288f414eb7' AND l.status IN ('claimed','verified')
   AND NOT EXISTS (SELECT 1 FROM public.family_weeks w WHERE w.kid_id = l.kid_id AND w.week_start = public.family_week_start(l.occurrence_date));
