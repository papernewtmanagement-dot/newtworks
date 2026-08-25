-- sp_backfill_weekly_2025_q1_q3
-- Backfill weekly Sales Points for 2025 Q1, Q2, Q3 (John, Tommy) using sp_walk_quarter:
-- even weekly production, tiered rate applied to the running cumulative, so points rise
-- faster later in the quarter. Quarter boundaries come from current_cycle_info only.
-- The production-derived total equals the stored quarter close for every member/quarter
-- here (scale factor 1.000000), so nothing is being stretched to fit.
--
-- 2023 and 2024 are deliberately NOT backfilled: producer_production for those years is an
-- annual figure already divided flat across twelve identical months, and the stored close
-- totals repeat across quarters, so any walk would be invented.
--
-- Step 1 moves each close row from the last Saturday of the CALENDAR quarter onto the State
-- Farm cycle_end Saturday (one week later). Step 2 fills weeks 1..12 ahead of it.
DO $$
DECLARE
  v_agency   uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_q        record;
  v_cycle    record;
  v_close_id uuid;
  v_rep_id   uuid;
  v_detail   public.weekly_cpr_team_detail;
  v_w        record;
BEGIN
  FOR v_q IN
    SELECT * FROM (VALUES
      (DATE '2025-03-29', DATE '2025-02-15'),
      (DATE '2025-06-28', DATE '2025-05-15'),
      (DATE '2025-09-27', DATE '2025-08-15')
    ) AS t(stored_on, any_date_in_quarter)
  LOOP
    SELECT * INTO v_cycle FROM public.current_cycle_info(v_agency, v_q.any_date_in_quarter);

    SELECT id INTO v_close_id
    FROM public.weekly_cpr_reports
    WHERE agency_id = v_agency AND week_ending_date = v_q.stored_on;

    CONTINUE WHEN v_close_id IS NULL;

    -- 1. park the close row on the true cycle end
    IF NOT EXISTS (SELECT 1 FROM public.weekly_cpr_reports
                   WHERE agency_id = v_agency AND week_ending_date = v_cycle.cycle_end) THEN
      UPDATE public.weekly_cpr_reports
      SET week_ending_date = v_cycle.cycle_end, updated_at = now()
      WHERE id = v_close_id;
    END IF;

    -- 2. walk weeks 1..12 for each member holding a close figure
    FOR v_detail IN
      SELECT d.* FROM public.weekly_cpr_team_detail d
      WHERE d.weekly_cpr_report_id = v_close_id AND d.sales_points IS NOT NULL
    LOOP
      FOR v_w IN
        SELECT week_no, week_ending, sales_points_cum
        FROM public.sp_walk_quarter(v_agency, v_detail.team_member_id,
                                    v_q.any_date_in_quarter, v_detail.sales_points)
        WHERE week_ending < v_cycle.cycle_end
        ORDER BY week_no
      LOOP
        SELECT id INTO v_rep_id FROM public.weekly_cpr_reports
        WHERE agency_id = v_agency AND week_ending_date = v_w.week_ending;

        IF v_rep_id IS NULL THEN
          INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date, notes)
          VALUES (v_agency, v_w.week_ending,
                  'Sales Points backfilled 2026-08-25 from quarter close via sp_walk_quarter')
          RETURNING id INTO v_rep_id;
        END IF;

        IF NOT EXISTS (SELECT 1 FROM public.weekly_cpr_team_detail
                       WHERE weekly_cpr_report_id = v_rep_id
                         AND team_member_id = v_detail.team_member_id) THEN
          INSERT INTO public.weekly_cpr_team_detail
          SELECT * FROM jsonb_populate_record(
            NULL::public.weekly_cpr_team_detail,
            to_jsonb(v_detail) || jsonb_build_object(
              'id',                   gen_random_uuid(),
              'weekly_cpr_report_id', v_rep_id,
              'sales_points',         v_w.sales_points_cum,
              'created_at',           now(),
              'updated_at',           now()
            ));
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END $$;
