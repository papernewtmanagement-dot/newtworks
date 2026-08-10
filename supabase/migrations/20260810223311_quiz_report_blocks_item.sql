CREATE OR REPLACE FUNCTION public.quiz_report_block_item()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  UPDATE public.quiz_items SET report_blocked = true, updated_at = now() WHERE id = NEW.item_id;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS quiz_report_blocks_item ON public.quiz_item_reports;
CREATE TRIGGER quiz_report_blocks_item
  AFTER INSERT ON public.quiz_item_reports
  FOR EACH ROW EXECUTE FUNCTION public.quiz_report_block_item();
