-- Peter 2026-09-15: only the owner edits checklist items; each item can carry a
-- link; items can be reordered; the explanation is edited on its own.

ALTER TABLE public.checklist_items ADD COLUMN IF NOT EXISTS link_url text;
COMMENT ON COLUMN public.checklist_items.link_url IS 'Optional link for the item (the ECRM list, the page it is worked on). Shown as an Open link on the row.';

-- Write access narrows from owner-or-manager to owner alone.
DROP POLICY IF EXISTS checklist_items_admin_write ON public.checklist_items;
CREATE POLICY checklist_items_owner_write ON public.checklist_items
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
         AND COALESCE(public.current_app_user_role() = 'owner', false))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
              AND COALESCE(public.current_app_user_role() = 'owner', false));

-- Owner guard used by every checklist edit entry point. One place, so the
-- answer can never drift between them.
CREATE OR REPLACE FUNCTION public.checklist_require_owner()
RETURNS void
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE='42501';
  END IF;
  IF NOT COALESCE(public.current_app_user_role() = 'owner', false) THEN
    RAISE EXCEPTION 'only the owner can change the checklist' USING ERRCODE='42501';
  END IF;
END;
$function$;

-- Save a title, its explanation, and its link. Any argument left NULL is left
-- alone, so the explanation can be edited on its own without resending the
-- title. Passing an empty string clears the explanation or the link.
CREATE OR REPLACE FUNCTION public.checklist_item_save(
  p_id uuid,
  p_title text DEFAULT NULL,
  p_help_text text DEFAULT NULL,
  p_link_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_link text;
  v_row public.checklist_items%ROWTYPE;
BEGIN
  PERFORM public.checklist_require_owner();

  IF p_title IS NOT NULL AND btrim(p_title) = '' THEN
    RAISE EXCEPTION 'the title cannot be empty' USING ERRCODE='22023';
  END IF;

  v_link := NULLIF(btrim(COALESCE(p_link_url, '')), '');
  IF v_link IS NOT NULL AND v_link !~* '^https?://' THEN
    RAISE EXCEPTION 'a link has to start with http:// or https://' USING ERRCODE='22023';
  END IF;

  UPDATE public.checklist_items i
  SET title     = COALESCE(NULLIF(btrim(p_title), ''), i.title),
      help_text = CASE WHEN p_help_text IS NULL THEN i.help_text
                       ELSE NULLIF(btrim(p_help_text), '') END,
      link_url  = CASE WHEN p_link_url IS NULL THEN i.link_url ELSE v_link END,
      updated_at = now()
  WHERE i.id = p_id AND i.agency_id = v_agency
  RETURNING i.* INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'no such checklist item' USING ERRCODE='22023';
  END IF;

  RETURN jsonb_build_object('id', v_row.id, 'title', v_row.title,
                            'help_text', v_row.help_text, 'link_url', v_row.link_url,
                            'sort_order', v_row.sort_order);
END;
$function$;

-- Move an item one place up or down inside its own list (team or personal),
-- then renumber that list in tens so the order stays easy to read.
CREATE OR REPLACE FUNCTION public.checklist_item_move(p_id uuid, p_direction text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_scope text;
  v_pos int;
  v_count int;
BEGIN
  PERFORM public.checklist_require_owner();

  IF lower(COALESCE(p_direction, '')) NOT IN ('up', 'down') THEN
    RAISE EXCEPTION 'direction has to be up or down' USING ERRCODE='22023';
  END IF;

  SELECT scope INTO v_scope FROM public.checklist_items
  WHERE id = p_id AND agency_id = v_agency;
  IF v_scope IS NULL THEN
    RAISE EXCEPTION 'no such checklist item' USING ERRCODE='22023';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp_unused_guard (x int);  -- never used; kept out of RPC path below

  WITH ordered AS (
    SELECT id, row_number() OVER (ORDER BY sort_order, title) AS rn
    FROM public.checklist_items
    WHERE agency_id = v_agency AND scope = v_scope
  )
  SELECT rn, (SELECT COUNT(*) FROM ordered) INTO v_pos, v_count
  FROM ordered WHERE id = p_id;

  IF (lower(p_direction) = 'up' AND v_pos = 1)
     OR (lower(p_direction) = 'down' AND v_pos = v_count) THEN
    RETURN jsonb_build_object('moved', false, 'scope', v_scope, 'position', v_pos);
  END IF;

  -- Renumber the whole list in tens, with this item's rank nudged half a step
  -- past its neighbour so it lands on the other side of it.
  WITH ordered AS (
    SELECT id, row_number() OVER (ORDER BY sort_order, title) AS rn
    FROM public.checklist_items
    WHERE agency_id = v_agency AND scope = v_scope
  ),
  nudged AS (
    SELECT id,
           CASE WHEN id = p_id AND lower(p_direction) = 'up'   THEN rn - 1.5
                WHEN id = p_id AND lower(p_direction) = 'down' THEN rn + 1.5
                ELSE rn::numeric END AS rank
    FROM ordered
  ),
  renumbered AS (
    SELECT id, (row_number() OVER (ORDER BY rank)) * 10 AS new_order FROM nudged
  )
  UPDATE public.checklist_items i
  SET sort_order = r.new_order, updated_at = now()
  FROM renumbered r
  WHERE i.id = r.id AND i.sort_order IS DISTINCT FROM r.new_order;

  RETURN jsonb_build_object('moved', true, 'scope', v_scope);
END;
$function$;

DROP TABLE IF EXISTS pg_temp_unused_guard;

GRANT EXECUTE ON FUNCTION public.checklist_item_save(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.checklist_item_move(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.checklist_require_owner() TO authenticated;
