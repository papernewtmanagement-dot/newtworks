-- The freeze fires the moment a CPR week goes to the team. Nobody has to remember it.
CREATE OR REPLACE FUNCTION public.trg_freeze_sales_points_on_send()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.sent_to_team_at IS NOT NULL AND OLD.sent_to_team_at IS NULL THEN
    PERFORM public.freeze_sales_points_for_week(NEW.agency_id, NEW.week_ending_date);
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS freeze_sales_points_on_send ON public.weekly_cpr_reports;
CREATE TRIGGER freeze_sales_points_on_send
  AFTER UPDATE OF sent_to_team_at ON public.weekly_cpr_reports
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_freeze_sales_points_on_send();
