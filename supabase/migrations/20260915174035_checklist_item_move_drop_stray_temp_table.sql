-- A CREATE TEMP TABLE inside a function called over PostgREST returns HTTP 400
-- even when the function runs clean. It was left in by mistake and does nothing.
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
