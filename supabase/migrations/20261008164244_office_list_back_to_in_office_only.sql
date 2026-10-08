-- Peter 2026-10-08: remote teammates don't need to see the office list. Everyone who can submit
-- something sees what others submitted: the office list is for in-office teammates (who request
-- from it), prize ideas are for everyone. The board goes back to inventory_can_use for both seeing
-- and tapping; inventory_can_see is no longer used and is dropped.
DO $$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.family_inventory_board(text)'::regprocedure);
  IF position('IF NOT public.inventory_can_see(p_location) THEN' in v_def) = 0 THEN
    RAISE EXCEPTION 'family_inventory_board access check not found; not changed.';
  END IF;
  EXECUTE replace(v_def, 'IF NOT public.inventory_can_see(p_location) THEN', 'IF NOT public.inventory_can_use(p_location) THEN');
END $$;
DROP FUNCTION IF EXISTS public.inventory_can_see(text);
