-- Peter 2026-09-22: Elliott's Clean Loft & Spare Room is a bigger job than 10 minutes.
-- Two rooms, everything off the floor and put away, pillows and blankets, trash: about 20 minutes for an 8-year-old.
UPDATE public.family_chores SET est_minutes = 20, pay = public.family_minutes_pay(20, agency_id)
 WHERE id = 'aec33b4a-3f9c-4e6a-b50b-0dadf7ae0030';
-- This week is still open, so its entries take the new price.
UPDATE public.family_chore_log l SET amount = public.family_log_amount(l.chore_id, l.status, l.occurrence_date), updated_at = now()
 WHERE l.chore_id = 'aec33b4a-3f9c-4e6a-b50b-0dadf7ae0030' AND l.status IN ('claimed','verified')
   AND NOT EXISTS (SELECT 1 FROM public.family_weeks w WHERE w.kid_id = l.kid_id AND w.week_start = public.family_week_start(l.occurrence_date));
