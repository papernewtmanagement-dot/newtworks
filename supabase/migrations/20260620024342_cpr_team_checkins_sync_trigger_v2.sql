-- =============================================================
-- TRIGGER — sync team_checkins (Telegram source-of-truth) into the
-- current week's weekly_cpr_team_detail row.
--
-- DESIGN
--   • Fires AFTER INSERT or UPDATE on team_checkins.
--   • Scope: midday + eod checkins only (those carry quotes_week and
--     sales_points_quarter values; morning checkins do not).
--   • Computes week-ending Saturday on/after checkin_date and ensures
--     a weekly_cpr_reports row exists for that week (creates a stub
--     if missing). Then ensures a weekly_cpr_team_detail row exists
--     for the (report, team_member) pair.
--   • Always overwrites quotes_discussed and sales_points from the
--     latest incoming checkin. Telegram is the authoritative source;
--     manual edits on the CPR page are durable until the next
--     telegram checkin lands.
-- =============================================================

CREATE OR REPLACE FUNCTION public.team_checkins_sync_to_cpr_detail()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_week_end       date;
  v_report_id      uuid;
  v_detail_id      uuid;
BEGIN
  IF NEW.team_id IS NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.checkin_type NOT IN ('midday', 'eod') THEN
    RETURN NEW;
  END IF;
  IF NEW.quotes_week IS NULL AND NEW.sales_points_quarter IS NULL THEN
    RETURN NEW;
  END IF;

  v_week_end := NEW.checkin_date
              + ((6 - EXTRACT(DOW FROM NEW.checkin_date)::int) % 7);

  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = NEW.agency_id
    AND week_ending_date = v_week_end;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date, created_at, updated_at)
    VALUES (NEW.agency_id, v_week_end, now(), now())
    RETURNING id INTO v_report_id;
  END IF;

  SELECT id INTO v_detail_id
  FROM public.weekly_cpr_team_detail
  WHERE weekly_cpr_report_id = v_report_id
    AND team_member_id       = NEW.team_id;

  IF v_detail_id IS NULL THEN
    INSERT INTO public.weekly_cpr_team_detail (
      agency_id, weekly_cpr_report_id, team_member_id,
      quotes_discussed, sales_points,
      created_at, updated_at
    ) VALUES (
      NEW.agency_id, v_report_id, NEW.team_id,
      CASE WHEN NEW.quotes_week         IS NOT NULL THEN NEW.quotes_week::integer ELSE NULL END,
      NEW.sales_points_quarter,
      now(), now()
    );
  ELSE
    UPDATE public.weekly_cpr_team_detail
       SET quotes_discussed = COALESCE(NEW.quotes_week::integer, quotes_discussed),
           sales_points     = COALESCE(NEW.sales_points_quarter,   sales_points),
           updated_at       = now()
     WHERE id = v_detail_id;
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'team_checkins_sync_to_cpr_detail: % (sqlstate %)', SQLERRM, SQLSTATE;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS team_checkins_sync_to_cpr_detail_trigger ON public.team_checkins;
CREATE TRIGGER team_checkins_sync_to_cpr_detail_trigger
AFTER INSERT OR UPDATE OF quotes_week, sales_points_quarter, team_id, checkin_type
ON public.team_checkins
FOR EACH ROW
EXECUTE FUNCTION public.team_checkins_sync_to_cpr_detail();

-- Backfill: replay the latest midday/eod checkin per teammate for the
-- 6/14-6/20 week into weekly_cpr_team_detail for tonight's send.
DO $$
DECLARE
  v_week_end date := '2026-06-20'::date;
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_report_id uuid;
  r record;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = v_agency_id AND week_ending_date = v_week_end;
  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date, created_at, updated_at)
    VALUES (v_agency_id, v_week_end, now(), now())
    RETURNING id INTO v_report_id;
  END IF;

  FOR r IN
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id, tc.quotes_week, tc.sales_points_quarter
    FROM public.team_checkins tc
    WHERE tc.agency_id = v_agency_id
      AND tc.checkin_date BETWEEN v_week_end - 6 AND v_week_end
      AND tc.checkin_type IN ('midday','eod')
      AND tc.team_id IS NOT NULL
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  LOOP
    INSERT INTO public.weekly_cpr_team_detail (
      agency_id, weekly_cpr_report_id, team_member_id,
      quotes_discussed, sales_points,
      created_at, updated_at
    ) VALUES (
      v_agency_id, v_report_id, r.team_id,
      CASE WHEN r.quotes_week IS NOT NULL THEN r.quotes_week::integer ELSE NULL END,
      r.sales_points_quarter,
      now(), now()
    )
    ON CONFLICT (weekly_cpr_report_id, team_member_id) DO UPDATE
      SET quotes_discussed = COALESCE(EXCLUDED.quotes_discussed, public.weekly_cpr_team_detail.quotes_discussed),
          sales_points     = COALESCE(EXCLUDED.sales_points,     public.weekly_cpr_team_detail.sales_points),
          updated_at       = now();
  END LOOP;
END $$;
