CREATE OR REPLACE FUNCTION public.quiz_report_block_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public.quiz_items SET report_blocked = true, updated_at = now() WHERE id = NEW.item_id;
  RETURN NEW;
END;
$function$;
