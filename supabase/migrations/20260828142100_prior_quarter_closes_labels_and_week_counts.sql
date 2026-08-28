-- prior_quarter_closes(agency, ref_date, count)
--
-- Returns the last N COMPLETED State Farm quarters before ref_date, newest first,
-- with the close Saturday, the cycle start, the real number of weeks in that
-- quarter, and the quarter's display label.
--
-- WHY THIS EXISTS: CPRDetail.jsx derived both the close dates and the labels
-- itself. Two defects came out of that:
--   1. The label was read off the calendar month of the CLOSE SATURDAY. A State
--      Farm quarter closes on the Saturday of the week containing the calendar
--      quarter's last day, so that Saturday usually falls in the NEXT calendar
--      month -- Q2 2026 closes 2026-07-04 (July) and was labelled "Q3 2026".
--      Wrong on 24 of the 28 quarters from 2023 through 2029, and wrong on the
--      YEAR too whenever the close crosses New Year (Q4 2025 closes 2026-01-03
--      and was labelled "Q1 2026").
--   2. Close dates were walked back a fixed 91 days at a time. Quarters are not
--      always 91 days: Q4 2023, Q4 2028 and Q3 2029 run 14 weeks, Q1 2029 runs
--      12. Fixed stepping drifts off the real closes.
--
-- The label is the calendar quarter of cycle_start. cycle_start is always the
-- day after the previous quarter's close, which is always inside the first week
-- of its own calendar quarter, so this is exact. Verified identical to the
-- alternative derivation (calendar quarter of close_date - 6 days) on every
-- quarter from 2023 Q1 through 2029 Q4.
--
-- Quarter boundaries come only from current_cycle_info, per the locked rule that
-- it is the single source of quarter boundaries. This function must never
-- reimplement that math.

CREATE OR REPLACE FUNCTION public.prior_quarter_closes(
  p_agency_id uuid,
  p_ref_date  date,
  p_count     integer DEFAULT 4
)
RETURNS TABLE(
  close_date       date,
  cycle_start      date,
  weeks_in_quarter integer,
  quarter_label    text
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_cursor date;
  v_start  date;
  v_end    date;
  i        integer;
BEGIN
  IF p_agency_id IS NULL OR p_ref_date IS NULL OR COALESCE(p_count, 0) < 1 THEN
    RETURN;
  END IF;

  -- Start from the cycle the reference date sits in, then step back one
  -- completed quarter at a time. The day before a cycle starts IS the previous
  -- cycle's close Saturday.
  SELECT c.cycle_start INTO v_start
  FROM current_cycle_info(p_agency_id, p_ref_date) c;

  IF v_start IS NULL THEN
    RETURN;
  END IF;

  v_cursor := v_start - 1;

  FOR i IN 1..p_count LOOP
    SELECT c.cycle_start, c.cycle_end INTO v_start, v_end
    FROM current_cycle_info(p_agency_id, v_cursor) c;

    EXIT WHEN v_start IS NULL OR v_end IS NULL;

    close_date       := v_end;
    cycle_start      := v_start;
    weeks_in_quarter := ((v_end - v_start + 1) / 7);
    quarter_label    := 'Q' || EXTRACT(QUARTER FROM v_start)::int::text
                             || ' ' || EXTRACT(YEAR FROM v_start)::int::text;
    RETURN NEXT;

    v_cursor := v_start - 1;
  END LOOP;

  RETURN;
END;
$function$;

COMMENT ON FUNCTION public.prior_quarter_closes(uuid, date, integer) IS
'Last N completed State Farm quarters before a reference date, newest first: close Saturday, cycle start, real week count, and display label. Label = calendar quarter of cycle_start (NOT of the close Saturday -- the close usually falls in the next calendar month). Boundaries come from current_cycle_info only.';

GRANT EXECUTE ON FUNCTION public.prior_quarter_closes(uuid, date, integer) TO anon, authenticated;
