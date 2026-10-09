-- Peter 2026-10-08 (second follow-up): everyone on the team can see every prize cart idea and
-- what the office has asked for. An idea stays on the list until it's actually used for the
-- prize cart; going to Alvi at quarter close doesn't take it off.

-- 1. Seeing a list vs. changing it. Office: every agency login can see it; only office_can_stock()
--    (admins + in-office teammates) can tap or request (inventory_can_use, unchanged).
CREATE OR REPLACE FUNCTION public.inventory_can_see(p_location text)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT CASE p_location
    WHEN 'home'   THEN public.family_is_parent() OR public.auth_is_family()
    WHEN 'office' THEN COALESCE(public.current_app_user_role() IN ('owner', 'admin', 'staff', 'readonly', 'accountant'), false)
    ELSE false END;
$function$;
REVOKE EXECUTE ON FUNCTION public.inventory_can_see(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inventory_can_see(text) TO authenticated, service_role;

DO $$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.family_inventory_board(text)'::regprocedure);
  IF position('IF NOT public.inventory_can_use(p_location) THEN' in v_def) = 0 THEN
    RAISE EXCEPTION 'family_inventory_board access check not found; not changed.';
  END IF;
  EXECUTE replace(v_def, 'IF NOT public.inventory_can_use(p_location) THEN', 'IF NOT public.inventory_can_see(p_location) THEN');
END $$;

-- 2. An idea comes off the list only when it's used.
ALTER TABLE public.prize_cart_ideas ADD COLUMN IF NOT EXISTS used_at timestamptz;

DROP FUNCTION IF EXISTS public.prize_cart_ideas_mine();
CREATE OR REPLACE FUNCTION public.prize_cart_ideas_list()
 RETURNS TABLE(id uuid, idea text, link text, created_at timestamptz, submitted_by text, is_mine boolean, is_new boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('staff');
  RETURN QUERY
  SELECT i.id, i.idea, i.link, i.created_at,
         COALESCE(NULLIF(t.nickname, ''), t.first_name),
         i.team_member_id IS NOT DISTINCT FROM public.current_team_member_id(),
         i.sent_at IS NULL
  FROM public.prize_cart_ideas i
  LEFT JOIN public.team t ON t.id = i.team_member_id
  WHERE i.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND i.used_at IS NULL
  ORDER BY i.created_at;
END $function$;

-- Admins mark an idea used once it goes on the prize cart.
CREATE OR REPLACE FUNCTION public.prize_cart_idea_mark_used(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('admin');
  UPDATE public.prize_cart_ideas SET used_at = now() WHERE id = p_id AND used_at IS NULL;
END $function$;

-- Take an idea back: your own, or any as an admin.
CREATE OR REPLACE FUNCTION public.prize_cart_idea_remove(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('staff');
  DELETE FROM public.prize_cart_ideas
  WHERE id = p_id AND used_at IS NULL
    AND (team_member_id IS NOT DISTINCT FROM public.current_team_member_id() OR public.is_agency_admin());
END $function$;

REVOKE EXECUTE ON FUNCTION public.prize_cart_ideas_list() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_idea_mark_used(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prize_cart_ideas_list() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_idea_mark_used(uuid) TO authenticated, service_role;

-- 3. Quarter close sends Alvi every idea still on the list (new ones marked), not just the new ones.
DO $$
DECLARE v_def text; v_old text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.quarter_close_prize_cart_and_leaderboards(uuid,date)'::regprocedure);

  v_old := $o$  SELECT array_agg(i.id ORDER BY i.created_at),
         string_agg('• ' || i.idea$o$;
  v_new := $n$  SELECT array_agg(i.id ORDER BY i.created_at) FILTER (WHERE i.sent_at IS NULL),
         string_agg('• ' || CASE WHEN i.sent_at IS NULL THEN 'NEW: ' ELSE '' END || i.idea$n$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'close: idea list block not found'; END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := $o$  WHERE i.agency_id = p_agency_id AND i.sent_at IS NULL;$o$;
  v_new := $n$  WHERE i.agency_id = p_agency_id AND i.used_at IS NULL;$n$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'close: idea filter not found'; END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := $o$'Prize ideas from the team:'$o$;
  v_new := $n$'Prize ideas from the team (they stay on the list until you mark one used on the Requests page):'$n$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'close: idea heading not found'; END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := $o$'prize_ideas_sent', COALESCE(cardinality(v_idea_ids), 0)$o$;
  v_new := $n$'new_prize_ideas_sent', COALESCE(cardinality(v_idea_ids), 0)$n$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'close: result key not found'; END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE v_def;
END $$;

