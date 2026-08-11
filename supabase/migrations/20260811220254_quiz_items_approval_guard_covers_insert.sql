CREATE OR REPLACE FUNCTION public.quiz_items_require_valid_options()
RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE
  opt_count integer;
  correct_count integer;
BEGIN
  IF NEW.status = 'approved'
     AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') THEN
    SELECT count(*), count(*) FILTER (WHERE is_correct)
      INTO opt_count, correct_count
      FROM public.quiz_item_options
      WHERE item_id = NEW.id;
    IF opt_count <> 4 OR correct_count <> 1 THEN
      RAISE EXCEPTION 'Cannot approve quiz item: needs exactly 4 options with exactly 1 marked correct.';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER quiz_items_approval_guard ON public.quiz_items;
CREATE TRIGGER quiz_items_approval_guard
  BEFORE INSERT OR UPDATE ON public.quiz_items
  FOR EACH ROW EXECUTE FUNCTION public.quiz_items_require_valid_options();
