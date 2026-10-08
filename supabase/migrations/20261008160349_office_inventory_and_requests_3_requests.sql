-- 4. Running low and Undo: allowed for whoever may use that item's list.
CREATE OR REPLACE FUNCTION public.family_inventory_mark_low(p_item_id uuid, p_dancer text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_last text; v_loc text;
BEGIN
  PERFORM public.require_login('any');
  SELECT location INTO v_loc FROM public.family_inventory_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That item is not on the list.'; END IF;
  IF NOT public.inventory_can_use(v_loc) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT e.kind INTO v_last FROM public.family_inventory_events e
  WHERE e.item_id = p_item_id ORDER BY e.at DESC, e.seq DESC LIMIT 1;
  IF v_last = 'low' THEN RETURN; END IF;  -- already tapped; one open tap per item
  INSERT INTO public.family_inventory_events (item_id, kind, dancer)
  VALUES (p_item_id, 'low', NULLIF(btrim(COALESCE(p_dancer, '')), ''));
END $function$;

CREATE OR REPLACE FUNCTION public.family_inventory_unmark_low(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_last public.family_inventory_events; v_loc text;
BEGIN
  PERFORM public.require_login('any');
  SELECT location INTO v_loc FROM public.family_inventory_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  IF NOT public.inventory_can_use(v_loc) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT e.* INTO v_last FROM public.family_inventory_events e
  WHERE e.item_id = p_item_id ORDER BY e.at DESC, e.seq DESC LIMIT 1;
  IF v_last.kind = 'low' THEN
    DELETE FROM public.family_inventory_events WHERE id = v_last.id;
  END IF;
END $function$;

-- 5. Snack request: puts the snack on the office list if it isn't there, then taps it Running low.
CREATE OR REPLACE FUNCTION public.office_request_snack(p_name text, p_dancer text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_name text := btrim(COALESCE(p_name, '')); v_id uuid;
BEGIN
  PERFORM public.require_login('staff');
  IF NOT public.inventory_can_use('office') THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'Type the snack you want.'; END IF;
  IF length(v_name) > 80 THEN RAISE EXCEPTION 'Keep the snack name short.'; END IF;
  SELECT id INTO v_id FROM public.family_inventory_items
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND location = 'office' AND lower(btrim(name)) = lower(v_name);
  IF v_id IS NULL THEN
    INSERT INTO public.family_inventory_items (agency_id, name, section, location, amount)
    VALUES ('126794dd-25ff-47d2-a436-724499733365'::uuid, v_name, 'SNACKS', 'office', 1)
    RETURNING id INTO v_id;
  END IF;
  PERFORM public.family_inventory_mark_low(v_id, p_dancer);
  RETURN v_id;
END $function$;

-- 6. Prize cart ideas from the team. They wait here until the quarter's prize cart close sends them to Alvi.
CREATE TABLE IF NOT EXISTS public.prize_cart_ideas (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  idea text NOT NULL,
  link text,
  team_member_id uuid REFERENCES public.team(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);
ALTER TABLE public.prize_cart_ideas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.prize_cart_ideas FROM anon;
DROP POLICY IF EXISTS prize_cart_ideas_admin_all ON public.prize_cart_ideas;
CREATE POLICY prize_cart_ideas_admin_all ON public.prize_cart_ideas FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.is_agency_admin()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.is_agency_admin()));

CREATE OR REPLACE FUNCTION public.prize_cart_idea_add(p_idea text, p_link text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_idea text := btrim(COALESCE(p_idea, '')); v_link text := NULLIF(btrim(COALESCE(p_link, '')), ''); v_id uuid;
BEGIN
  PERFORM public.require_login('staff');
  IF v_idea = '' THEN RAISE EXCEPTION 'Type your prize idea.'; END IF;
  IF length(v_idea) > 200 THEN RAISE EXCEPTION 'Keep the idea under 200 characters.'; END IF;
  IF v_link IS NOT NULL AND v_link !~* '^https?://' THEN v_link := 'https://' || v_link; END IF;
  INSERT INTO public.prize_cart_ideas (idea, link, team_member_id)
  VALUES (v_idea, v_link, public.current_team_member_id())
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;

-- The signed-in person's own ideas that haven't gone to Alvi yet.
CREATE OR REPLACE FUNCTION public.prize_cart_ideas_mine()
 RETURNS TABLE(id uuid, idea text, link text, created_at timestamptz)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT i.id, i.idea, i.link, i.created_at
  FROM public.prize_cart_ideas i
  WHERE i.sent_at IS NULL
    AND i.team_member_id IS NOT DISTINCT FROM public.current_team_member_id()
    AND public.current_app_user_role() IS NOT NULL
  ORDER BY i.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.prize_cart_idea_remove(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('staff');
  DELETE FROM public.prize_cart_ideas
  WHERE id = p_id AND sent_at IS NULL
    AND (team_member_id IS NOT DISTINCT FROM public.current_team_member_id() OR public.is_agency_admin());
END $function$;

-- 7. Meal plan links recipes only to house items, never to the office list.
CREATE OR REPLACE FUNCTION public.family_meal_link_inventory(p_item text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT NULLIF(i->>'inventory_item_id', '')::uuid
       FROM public.family_meals m, jsonb_array_elements(COALESCE(m.ingredients, '[]'::jsonb)) i
      WHERE lower(i->>'item') = lower(btrim(p_item)) AND NULLIF(i->>'inventory_item_id', '') IS NOT NULL
      LIMIT 1),
    (SELECT it.id
       FROM public.family_inventory_items it
       CROSS JOIN LATERAL (
         SELECT array_agg(regexp_replace(tok, '(es|s)$', '')) AS toks
         FROM regexp_split_to_table(lower(regexp_replace(it.name, '^spices\s*-\s*', '', 'i')), '[^a-zñé]+') tok
         WHERE tok NOT IN ('', 'other', 'and', 'or')
       ) t
      WHERE it.location = 'home'
        AND it.section NOT IN ('CLEANING SUPPLIES', 'HOME GOODS', 'PERSONAL CARE')
        AND cardinality(t.toks) > 0
        AND NOT EXISTS (SELECT 1 FROM unnest(t.toks) tok WHERE lower(COALESCE(p_item, '')) !~ ('\m' || tok))
      ORDER BY cardinality(t.toks) DESC, length(it.name) DESC
      LIMIT 1));
$function$;

-- 8. New functions: no anonymous calls.
REVOKE EXECUTE ON FUNCTION public.inventory_can_use(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_inventory_board(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.office_request_snack(text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_idea_add(text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_ideas_mine() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_idea_remove(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.inventory_can_use(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.family_inventory_board(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.office_request_snack(text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_idea_add(text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_ideas_mine() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_idea_remove(uuid) TO authenticated, service_role;
