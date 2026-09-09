-- Peter rulings 2026-09-09, clarified again 2026-09-09 pm.
--
-- 1. An office closure (company_holidays.observance = 'closed') on a Mon-Fri
--    voids all other time off filed for that day. Nothing coexists with a
--    closed day. Enforced two ways: a forward guard that blocks the filing,
--    and a sweep that cancels rows already sitting on a closed day.
--
-- 2. Win the Week quote targets and Sales Points requirements NEVER prorate
--    for a holiday. Untouched here on purpose.
--
-- 3. The REWARD does interact. Win the week in week N; if week N+1 already
--    contains a closure, that closure IS the week N+1 day-off reward. No
--    separate Win-the-Week day off is granted that week. Peter's words:
--    "if the team wins the week in one week, then the following week if
--    there's already an office closure for a holiday, that counts as their
--    day off reward for winning the week... there wouldn't be a default
--    extra win the week time off." They may still REQUEST more time off
--    (unlimited paid time off) - that path is unaffected.

-- ---------------------------------------------------------------------------
-- Helper: is this date a weekday the office is closed? Returns the holiday
-- name, or NULL. SECURITY DEFINER so the guard below cannot be dodged by a
-- caller who simply cannot see company_holidays under row-level security.
-- No observed-day substitution: a closure that falls on a weekend never
-- affects a weekday calculation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.closed_holiday_name(p_agency_id uuid, p_date date)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT h.holiday_name
  FROM public.company_holidays h
  WHERE h.agency_id = p_agency_id
    AND h.is_active
    AND h.observance = 'closed'
    AND h.holiday_date = p_date
    AND EXTRACT(ISODOW FROM h.holiday_date) BETWEEN 1 AND 5
  ORDER BY h.holiday_name
  LIMIT 1;
$function$;

REVOKE EXECUTE ON FUNCTION public.closed_holiday_name(uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.closed_holiday_name(uuid, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.closed_holiday_name(uuid, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- Forward guard: nothing gets filed on a closed weekday.
-- Skipped deliberately for:
--   - the closure day-off records themselves (derived_from_holiday_id)
--   - Win-the-Week reward rows (derived_from_standing_pref_id); the
--     materializer has its own week-level closure gate, and raising here
--     would abort the whole Sunday automation run
--   - preference-change and four-day-change requests, which are not days off
--   - multi-day ranges, so a week of vacation that happens to span
--     Thanksgiving is not rejected outright
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_tor_block_closed_day()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_holiday text;
BEGIN
  IF NEW.request_type IN ('standing_time_off_preference', 'four_day_off_change') THEN
    RETURN NEW;
  END IF;
  IF NEW.status IN ('denied', 'canceled', 'expired') THEN
    RETURN NEW;
  END IF;
  IF NEW.derived_from_holiday_id IS NOT NULL
     OR NEW.derived_from_standing_pref_id IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.start_date IS DISTINCT FROM NEW.end_date THEN
    RETURN NEW;
  END IF;

  v_holiday := public.closed_holiday_name(NEW.agency_id, NEW.start_date);
  IF v_holiday IS NULL THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'The office is closed on % for %. Everyone already has that day off, so time off cannot be filed for it. Pick another day.',
    to_char(NEW.start_date, 'FMDay, FMMonth FMDD'), v_holiday;
END $function$;

DROP TRIGGER IF EXISTS tor_block_closed_day ON public.time_off_requests;
CREATE TRIGGER tor_block_closed_day
  BEFORE INSERT OR UPDATE ON public.time_off_requests
  FOR EACH ROW EXECUTE FUNCTION public.tg_tor_block_closed_day();

-- ---------------------------------------------------------------------------
-- Sweep: cancel single-day time off already sitting on a closed weekday.
-- Catches rows that predate the guard, and rows that become collisions when a
-- holiday date is corrected by the seeder. Reward rows ARE included: a reward
-- chunk on a closed day is void, because the closure is the reward.
-- Forward-looking by default so closed history is never rewritten.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_time_off_on_closed_days(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_from_date date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_count int := 0;
  v_detail jsonb := '[]'::jsonb;
BEGIN
  WITH hits AS (
    SELECT r.id,
           r.start_date,
           public.closed_holiday_name(r.agency_id, r.start_date) AS holiday_name,
           COALESCE(t.first_name, 'unknown') AS who
    FROM public.time_off_requests r
    LEFT JOIN public.team t ON t.id = r.requester_team_id
    WHERE r.agency_id = p_agency_id
      AND r.start_date = r.end_date
      AND r.start_date >= p_from_date
      AND r.derived_from_holiday_id IS NULL
      AND r.request_type NOT IN ('standing_time_off_preference', 'four_day_off_change')
      AND r.status IN ('pending', 'voting', 'awaiting_decision', 'approved', 'flagged_case_by_case')
      AND public.closed_holiday_name(r.agency_id, r.start_date) IS NOT NULL
  ), upd AS (
    UPDATE public.time_off_requests r
       SET status        = 'canceled',
           decided_at    = NOW(),
           decision_note = 'Canceled automatically: the office is closed that day, so everyone already has it off.'
      FROM hits
     WHERE r.id = hits.id
    RETURNING r.id
  )
  SELECT COUNT(*)::int,
         COALESCE(jsonb_agg(jsonb_build_object(
           'who', hits.who, 'date', hits.start_date, 'holiday', hits.holiday_name)), '[]'::jsonb)
    INTO v_count, v_detail
  FROM hits;

  RETURN jsonb_build_object('canceled', v_count, 'detail', v_detail, 'from_date', p_from_date);
END $function$;

REVOKE EXECUTE ON FUNCTION public.void_time_off_on_closed_days(uuid, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.void_time_off_on_closed_days(uuid, date) FROM anon;
REVOKE EXECUTE ON FUNCTION public.void_time_off_on_closed_days(uuid, date) FROM authenticated;
