-- Exact-match string replace with an asserted match count. Used by replace-based function
-- migrations so a stale or drifted function body aborts the migration instead of silently
-- skipping an edit.
CREATE OR REPLACE FUNCTION public.fn_source_replace_exact(p_src text, p_old text, p_new text, p_expect int)
RETURNS text
LANGUAGE plpgsql
AS $f$
DECLARE
  v_n int;
BEGIN
  v_n := (length(p_src) - length(replace(p_src, p_old, ''))) / NULLIF(length(p_old), 0);
  IF v_n IS DISTINCT FROM p_expect THEN
    RAISE EXCEPTION 'fn_source_replace_exact: expected % match(es), found % for: %', p_expect, v_n, left(p_old, 160);
  END IF;
  RETURN replace(p_src, p_old, p_new);
END
$f$;

-- Share of the Monday-to-Friday workdays in the week ending p_week_end_date (a Saturday) that
-- fall inside a person's employment window [p_start_date, p_end_date]. NULL start = employed
-- since before the week; NULL end = still employed. Same 5-workday model as
-- get_wtw_am_seat_weights (Peter 2026-09-02): last day Tuesday = 2 of 5 = 0.4; a week that
-- starts after the last day = 0.
CREATE OR REPLACE FUNCTION public.team_week_workday_fraction(p_start_date date, p_end_date date, p_week_end_date date)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $f$
  SELECT LEAST(5, GREATEST(0,
           (LEAST(COALESCE(p_end_date, p_week_end_date - 1), p_week_end_date - 1)
            - GREATEST(COALESCE(p_start_date, p_week_end_date - 5), p_week_end_date - 5)) + 1))::numeric / 5.0;
$f$;
