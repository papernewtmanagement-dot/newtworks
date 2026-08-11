CREATE OR REPLACE FUNCTION public.quiz_record_serve(p_item_id uuid, p_was_correct boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  UPDATE public.quiz_items
     SET times_served  = times_served + 1,
         times_correct = times_correct + CASE WHEN p_was_correct THEN 1 ELSE 0 END,
         updated_at    = now()
   WHERE id = p_item_id
     AND agency_id IN (SELECT u.agency_id FROM users u
                       WHERE u.auth_user_id = auth.uid());
END;
$function$;

REVOKE ALL ON FUNCTION public.quiz_record_serve(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quiz_record_serve(uuid, boolean) TO authenticated;
