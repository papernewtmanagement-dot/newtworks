-- interview_slot_grid: also return what the Interview Slots page needs to draw from it (Peter 2026-10-04: one
-- function per job; the page drops its own copy of the slot times). New optional p_include_vacation: when true,
-- slots in a vacation week come back blacked out with the vacation's label, so the page can show them and move
-- the week. Callers that leave it off get the same rows as before.
DROP FUNCTION IF EXISTS public.interview_slot_grid(uuid, date, date);

CREATE FUNCTION public.interview_slot_grid(p_agency_id uuid, p_from date, p_to date, p_include_vacation boolean DEFAULT false)
 RETURNS TABLE(slot_date date, start_at timestamp with time zone, end_at timestamp with time zone, tier text, blacked_out boolean,
               source text, manual_slot_id uuid, manual_note text, blackout_id uuid, recurring_blackout_id uuid,
               removed_whole boolean, vacation_series_id uuid, vacation_label text, vacation_original_week_start date,
               vacation_moved boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The interview slot schedule, kept in this one place (Peter 2026-10-04: one function per job). Every time set aside
-- for interviews between two dates, booked or not. Read by the hiring-interview-scheduler edge function (offers,
-- booking, rebooking), the Interview Slots page, and the onboarding coaching blocks, which never sit on one.
-- Weekly times (Peter 2026-09-11), 30 minutes each, Central time:
--   main    Mon/Tue 10:00, 1:00, 3:30 | Wed 10:00, 1:00 | Thu 1:00, 3:30 | Fri 10:00, 1:00, 3:30
--   backup  10:45 and 4:15, but no Wednesday-afternoon and no Thursday-morning backup ("secondary" tier; only
--           offered once the main times in the next 7 days are booked)
--   Fridays: the first Friday of the month has no morning times; the third has no times from noon on, backups included.
-- No slots in a vacation week (hiring_interview_vacation_series, each occurrence movable through
-- hiring_interview_vacation_moves); with p_include_vacation they come back blacked out, labeled, for the page.
-- One-off manual slots are added as main times (source 'manual', with their id and note). blacked_out = Peter cleared
-- the slot (hiring_interview_blackouts, hiring_interview_recurring_blackouts; ids returned); a blackout with no
-- times covers the day (removed_whole).
WITH days AS (
  SELECT d::date AS d FROM generate_series(p_from, p_to, interval '1 day') d
),
vac_all AS (
  SELECT COALESCE(mv.moved_to_week_start, occ.wk) AS wk, sr.id AS series_id, sr.label, occ.wk AS original_wk,
         COALESCE(mv.moved_to_week_start <> occ.wk, false) AS moved
    FROM hiring_interview_vacation_series sr
    CROSS JOIN LATERAL (SELECT (sr.anchor_week_start + n * 7 * GREATEST(1, COALESCE(NULLIF(sr.interval_weeks, 0), 13)))::date AS wk
                          FROM generate_series(0, 520) n) occ
    LEFT JOIN hiring_interview_vacation_moves mv ON mv.series_id = sr.id AND mv.original_week_start = occ.wk
   WHERE sr.agency_id = p_agency_id AND sr.is_active AND occ.wk BETWEEN p_from - 14 AND p_to + 7
  UNION ALL
  SELECT mv.moved_to_week_start, sr.id, sr.label, mv.original_week_start, mv.moved_to_week_start <> mv.original_week_start
    FROM hiring_interview_vacation_moves mv JOIN hiring_interview_vacation_series sr ON sr.id = mv.series_id
   WHERE mv.agency_id = p_agency_id AND sr.is_active
),
vac AS (
  SELECT DISTINCT ON (wk) wk, series_id, label, original_wk, moved FROM vac_all ORDER BY wk, moved DESC
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
         (days.d + times.t + interval '30 minutes') AT TIME ZONE 'America/Chicago' AS e, times.tier,
         'fixed'::text AS src, NULL::uuid AS manual_id, NULL::text AS note,
         vac.series_id AS vac_series, vac.label AS vac_label, vac.original_wk AS vac_original, vac.moved AS vac_moved
    FROM days JOIN times ON times.dow = extract(dow FROM days.d)::int
    LEFT JOIN vac ON vac.wk = days.d - extract(dow FROM days.d)::int
   WHERE (vac.wk IS NULL OR p_include_vacation)
     AND NOT (times.dow = 5 AND (extract(day FROM days.d)::int + 6) / 7 = 1 AND times.t < time '12:00')
     AND NOT (times.dow = 5 AND (extract(day FROM days.d)::int + 6) / 7 = 3 AND times.t >= time '12:00')
  UNION ALL
  SELECT m.slot_date, m.start_time, (m.slot_date + m.start_time) AT TIME ZONE 'America/Chicago',
         (m.slot_date + m.end_time) AT TIME ZONE 'America/Chicago', 'primary',
         'manual', m.id, m.note, NULL, NULL, NULL, NULL
    FROM hiring_interview_manual_slots m
   WHERE m.agency_id = p_agency_id AND m.slot_date BETWEEN p_from AND p_to
)
SELECT x.d, x.s, x.e, x.tier,
       (x.vac_series IS NOT NULL OR bo.id IS NOT NULL OR rb.id IS NOT NULL),
       x.src, x.manual_id, x.note, bo.id, rb.id,
       (x.vac_series IS NOT NULL OR COALESCE(bo.whole, false) OR COALESCE(rb.whole, false)),
       x.vac_series, x.vac_label, x.vac_original, x.vac_moved
  FROM slots x
  LEFT JOIN LATERAL (
    SELECT b.id, (b.start_time IS NULL OR b.end_time IS NULL) AS whole FROM hiring_interview_blackouts b
     WHERE b.agency_id = p_agency_id AND b.blackout_date = x.d
       AND (b.start_time IS NULL OR b.end_time IS NULL OR (x.t >= b.start_time AND x.t < b.end_time))
     ORDER BY (b.start_time IS NULL OR b.end_time IS NULL) DESC, b.id LIMIT 1) bo ON true
  LEFT JOIN LATERAL (
    SELECT r.id, (r.start_time IS NULL OR r.end_time IS NULL) AS whole FROM hiring_interview_recurring_blackouts r
     WHERE r.agency_id = p_agency_id AND r.weekday = extract(dow FROM x.d)::int
       AND x.d >= r.starts_on AND (r.ends_on IS NULL OR x.d <= r.ends_on)
       AND (r.start_time IS NULL OR r.end_time IS NULL OR (x.t >= r.start_time AND x.t < r.end_time))
     ORDER BY (r.start_time IS NULL OR r.end_time IS NULL) DESC, r.id LIMIT 1) rb ON true
 ORDER BY x.s;
$function$;

REVOKE ALL ON FUNCTION public.interview_slot_grid(uuid, date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.interview_slot_grid(uuid, date, date, boolean) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

