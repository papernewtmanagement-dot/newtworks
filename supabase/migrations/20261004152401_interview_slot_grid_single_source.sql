
CREATE OR REPLACE FUNCTION public.interview_slot_grid(p_agency_id uuid, p_from date, p_to date)
 RETURNS TABLE(slot_date date, start_at timestamptz, end_at timestamptz, tier text, blacked_out boolean)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- The interview slot schedule, kept in this one place (Peter 2026-10-04: one function per job). Every time set aside
-- for interviews between two dates, booked or not. Read by the hiring-interview-scheduler edge function (offers,
-- booking, rebooking), the Interview Slots page, and the onboarding coaching blocks, which never sit on one.
-- Weekly times (Peter 2026-09-11), 30 minutes each, Central time:
--   main    Mon/Tue 10:00, 1:00, 3:30 | Wed 10:00, 1:00 | Thu 1:00, 3:30 | Fri 10:00, 1:00, 3:30
--   backup  10:45 and 4:15, but no Wednesday-afternoon and no Thursday-morning backup ("secondary" tier; only
--           offered once the main times in the next 7 days are booked)
--   Fridays: the first Friday of the month has no morning times; the third has no times from noon on, backups included.
-- No slots in a vacation week (hiring_interview_vacation_series, each occurrence movable through
-- hiring_interview_vacation_moves). One-off manual slots are added as main times. blacked_out = Peter cleared the
-- slot (hiring_interview_blackouts, hiring_interview_recurring_blackouts); a blackout with no times covers the day.
WITH days AS (
  SELECT d::date AS d FROM generate_series(p_from, p_to, interval '1 day') d
),
vac AS (
  SELECT COALESCE(mv.moved_to_week_start, occ.wk) AS wk
    FROM hiring_interview_vacation_series sr
    CROSS JOIN LATERAL (SELECT (sr.anchor_week_start + n * 7 * GREATEST(1, COALESCE(NULLIF(sr.interval_weeks, 0), 13)))::date AS wk
                          FROM generate_series(0, 520) n) occ
    LEFT JOIN hiring_interview_vacation_moves mv ON mv.series_id = sr.id AND mv.original_week_start = occ.wk
   WHERE sr.agency_id = p_agency_id AND sr.is_active AND occ.wk BETWEEN p_from - 14 AND p_to + 7
  UNION
  SELECT mv.moved_to_week_start
    FROM hiring_interview_vacation_moves mv JOIN hiring_interview_vacation_series sr ON sr.id = mv.series_id
   WHERE mv.agency_id = p_agency_id AND sr.is_active
),
times(dow, t, tier) AS (VALUES
  (1, time '10:00', 'primary'), (1, time '13:00', 'primary'), (1, time '15:30', 'primary'), (1, time '10:45', 'secondary'), (1, time '16:15', 'secondary'),
  (2, time '10:00', 'primary'), (2, time '13:00', 'primary'), (2, time '15:30', 'primary'), (2, time '10:45', 'secondary'), (2, time '16:15', 'secondary'),
  (3, time '10:00', 'primary'), (3, time '13:00', 'primary'),                               (3, time '10:45', 'secondary'),
                                (4, time '13:00', 'primary'), (4, time '15:30', 'primary'),                                (4, time '16:15', 'secondary'),
  (5, time '10:00', 'primary'), (5, time '13:00', 'primary'), (5, time '15:30', 'primary'), (5, time '10:45', 'secondary'), (5, time '16:15', 'secondary')
),
slots AS (
  SELECT days.d, times.t, (days.d + times.t) AT TIME ZONE 'America/Chicago' AS s,
         (days.d + times.t + interval '30 minutes') AT TIME ZONE 'America/Chicago' AS e, times.tier
    FROM days JOIN times ON times.dow = extract(dow FROM days.d)::int
   WHERE NOT EXISTS (SELECT 1 FROM vac WHERE vac.wk = days.d - extract(dow FROM days.d)::int)
     AND NOT (times.dow = 5 AND (extract(day FROM days.d)::int + 6) / 7 = 1 AND times.t < time '12:00')
     AND NOT (times.dow = 5 AND (extract(day FROM days.d)::int + 6) / 7 = 3 AND times.t >= time '12:00')
  UNION ALL
  SELECT m.slot_date, m.start_time, (m.slot_date + m.start_time) AT TIME ZONE 'America/Chicago',
         (m.slot_date + m.end_time) AT TIME ZONE 'America/Chicago', 'primary'
    FROM hiring_interview_manual_slots m
   WHERE m.agency_id = p_agency_id AND m.slot_date BETWEEN p_from AND p_to
)
SELECT x.d, x.s, x.e, x.tier,
       EXISTS (SELECT 1 FROM hiring_interview_blackouts b
                WHERE b.agency_id = p_agency_id AND b.blackout_date = x.d
                  AND (b.start_time IS NULL OR b.end_time IS NULL OR (x.t >= b.start_time AND x.t < b.end_time)))
    OR EXISTS (SELECT 1 FROM hiring_interview_recurring_blackouts r
                WHERE r.agency_id = p_agency_id AND r.weekday = extract(dow FROM x.d)::int
                  AND x.d >= r.starts_on AND (r.ends_on IS NULL OR x.d <= r.ends_on)
                  AND (r.start_time IS NULL OR r.end_time IS NULL OR (x.t >= r.start_time AND x.t < r.end_time)))
  FROM slots x
 ORDER BY x.s;
$fn$;
GRANT EXECUTE ON FUNCTION public.interview_slot_grid(uuid, date, date) TO authenticated, service_role;

