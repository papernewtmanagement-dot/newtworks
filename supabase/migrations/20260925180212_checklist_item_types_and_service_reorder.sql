-- Peter 2026-09-25: the team checklist runs in four groups by type, in this
-- order: communications, sales, service, end of day. Each group gets one
-- background and the next group switches, on the Checklist tab and the CPR.
-- Two moves in the service group: Service tasks goes above Cases with no
-- tasks closed, and Onboarding cases goes under it.

ALTER TABLE public.checklist_items ADD COLUMN IF NOT EXISTS item_type text;

COMMENT ON COLUMN public.checklist_items.item_type IS
'The group a team item belongs to: communications, sales, service or end_of_day (Peter 2026-09-25). The team list runs in that order and each group shares one background, alternating, on the Checklist tab and the CPR. Personal items have none. checklist_item_move keeps each group in one piece: at the edge of a group, a move joins the next group instead of jumping past it.';

-- The order, with Peter's two moves, and each item's group.
UPDATE public.checklist_items i
SET sort_order = v.ord, item_type = v.typ, updated_at = now()
FROM (VALUES
  ('shared_folders',         10, 'communications'),
  ('texts',                  20, 'communications'),
  ('ooo_text_office',        30, 'communications'),
  ('mail',                   40, 'communications'),
  ('appointments',           50, 'communications'),
  ('opp_lists',              60, 'sales'),
  ('missing_phone',          70, 'sales'),
  ('dnc',                    80, 'sales'),
  ('opp_has_task',           90, 'sales'),
  ('sales_tasks',           100, 'sales'),
  ('campaign_leads',        110, 'sales'),
  ('billed_prior_month',    120, 'service'),
  ('service_tasks',         130, 'service'),
  ('ecrm_cases_closed',     140, 'service'),
  ('ecrm_onboarding_cases', 150, 'service'),
  ('claims',                160, 'service'),
  ('production_manager',    170, 'end_of_day'),
  ('deposits',              180, 'end_of_day')
) AS v(k, ord, typ)
WHERE i.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND i.scope = 'team'
  AND i.item_key = v.k;

-- Every team item has a group; personal items have none. A team item added
-- later without a group is refused, so the colors can never have a gap.
ALTER TABLE public.checklist_items DROP CONSTRAINT IF EXISTS checklist_items_item_type_check;
ALTER TABLE public.checklist_items ADD CONSTRAINT checklist_items_item_type_check CHECK (
  CASE WHEN scope = 'team'
       THEN COALESCE(item_type IN ('communications', 'sales', 'service', 'end_of_day'), false)
       ELSE item_type IS NULL
  END
);

-- Moving an item. Within its group it swaps with its neighbour, as before.
-- At the edge of its group it does not jump over the neighbour: it joins the
-- next group where it stands, so a group is never split in two. The next
-- press then moves it within its new group. Personal items have no group, so
-- they always swap.
CREATE OR REPLACE FUNCTION public.checklist_item_move(p_id uuid, p_direction text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_dir text := lower(COALESCE(p_direction, ''));
  v_scope text;
  v_type text;
  v_pos int;
  v_count int;
  v_next_type text;
BEGIN
  PERFORM public.require_login('staff');
  PERFORM public.checklist_require_owner();

  IF v_dir NOT IN ('up', 'down') THEN
    RAISE EXCEPTION 'direction has to be up or down' USING ERRCODE='22023';
  END IF;

  SELECT scope, item_type INTO v_scope, v_type FROM public.checklist_items
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

  IF (v_dir = 'up' AND v_pos = 1)
     OR (v_dir = 'down' AND v_pos = v_count) THEN
    RETURN jsonb_build_object('moved', false, 'scope', v_scope, 'position', v_pos);
  END IF;

  -- The neighbour it is about to pass.
  WITH ordered AS (
    SELECT id, item_type, row_number() OVER (ORDER BY sort_order, title) AS rn
    FROM public.checklist_items
    WHERE agency_id = v_agency AND scope = v_scope
  )
  SELECT item_type INTO v_next_type
  FROM ordered
  WHERE rn = v_pos + CASE WHEN v_dir = 'up' THEN -1 ELSE 1 END;

  IF v_type IS DISTINCT FROM v_next_type THEN
    UPDATE public.checklist_items
    SET item_type = v_next_type, updated_at = now()
    WHERE id = p_id AND agency_id = v_agency;
    RETURN jsonb_build_object('moved', true, 'scope', v_scope, 'item_type', v_next_type);
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
           CASE WHEN id = p_id AND v_dir = 'up'   THEN rn - 1.5
                WHEN id = p_id AND v_dir = 'down' THEN rn + 1.5
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

-- The group travels with each team item to the Checklist tab and to the CPR,
-- so both color from the same column.
DO $mig$
DECLARE
  v_def text;
  v_old text := E'''link_url'', i.link_url,\n           ''ticked_by''';
  v_new text := E'''link_url'', i.link_url, ''item_type'', i.item_type,\n           ''ticked_by''';
BEGIN
  SELECT pg_get_functiondef('public.daily_checklist_state(date)'::regprocedure) INTO v_def;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'daily_checklist_state: team item anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$mig$;

DO $mig$
DECLARE
  v_def text;
  v_old text := E'''sort_order'', i.sort_order,\n      ''done''';
  v_new text := E'''sort_order'', i.sort_order, ''item_type'', i.item_type,\n      ''done''';
BEGIN
  SELECT pg_get_functiondef('public.cpr_checklist_get(uuid)'::regprocedure) INTO v_def;
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'cpr_checklist_get: item anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$mig$;
