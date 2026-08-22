-- Switch the stamp criteria from role_category='Sales' to role_level IN ('Account Manager', 'Unit Manager').
-- This excludes any future AA who's tagged with role_category='Sales' but isn't actually AM-required for WtW.
CREATE OR REPLACE FUNCTION public.weekly_cpr_stamp_required_count()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.required_sales_members_count IS NULL THEN
    NEW.required_sales_members_count := (
      SELECT COUNT(*)::int
        FROM public.team t
       WHERE t.agency_id = NEW.agency_id
         AND t.category = 'agency'
         AND t.role_level IN ('Account Manager', 'Unit Manager')
         AND (t.start_date IS NULL OR t.start_date <= NEW.week_ending_date)
         AND (t.archived_at IS NULL OR t.archived_at::date > (NEW.week_ending_date - 6))
    );
  END IF;
  RETURN NEW;
END;
$fn$;

-- Re-stamp existing rows under the new criteria.
UPDATE public.weekly_cpr_reports r
SET required_sales_members_count = (
  SELECT COUNT(*)::int FROM public.team t
   WHERE t.agency_id = r.agency_id
     AND t.category = 'agency'
     AND t.role_level IN ('Account Manager', 'Unit Manager')
     AND (t.start_date IS NULL OR t.start_date <= r.week_ending_date)
     AND (t.archived_at IS NULL OR t.archived_at::date > (r.week_ending_date - 6))
);

-- Update the column comment for posterity
COMMENT ON COLUMN public.weekly_cpr_reports.required_sales_members_count IS
'Count of team members where role_level IN (Account Manager, Unit Manager) on the team during this week, stamped at INSERT. Locks historical truth so retroactive team changes do not shift prior-week pay math. compute_weekly_pay averages this column across the current cycle for the Manager Base Advance divisor.';

-- Verify
SELECT week_ending_date, required_sales_members_count
FROM weekly_cpr_reports
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND week_ending_date >= '2026-04-05'
ORDER BY week_ending_date;
