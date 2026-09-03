-- Step 1c: set resolution, per-set norm routing, set-aware serving and
-- save-acceptance. No behaviour change while fixed16_v1 is current.

CREATE OR REPLACE FUNCTION public.hiregauge_gma_current_set(p_agency uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT set_key FROM public.hiregauge_gma_item_sets
  WHERE agency_id = p_agency AND is_current
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_gma_candidate_set(p_candidate_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
-- The GMA item set a candidate is on. Order of authority:
--   1. hiring_candidates.gma_item_set (locked on first GMA answer);
--   2. the set that contains EVERY GMA item they have answered, preferring a
--      retired set (a candidate who answered a retired item never reads as
--      current);
--   3. the current set (nothing answered yet).
DECLARE
  v_agency uuid;
  v_locked text;
  v_inferred text;
BEGIN
  SELECT agency_id, gma_item_set INTO v_agency, v_locked
  FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency IS NULL THEN RETURN NULL; END IF;
  IF v_locked IS NOT NULL THEN RETURN v_locked; END IF;

  SELECT m.set_key INTO v_inferred
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  JOIN public.hiregauge_gma_item_set_members m ON m.item_id = r.item_id
  JOIN public.hiregauge_gma_item_sets s ON s.set_key = m.set_key
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_cognitive_gma'
  GROUP BY m.set_key, s.is_current, s.activated_at
  HAVING count(*) = (
    SELECT count(*) FROM public.hiregauge_candidate_responses r2
    JOIN public.hiregauge_instrument_items i2 ON i2.id = r2.item_id
    WHERE r2.candidate_id = p_candidate_id
      AND i2.section = 'newtworks_v2_cognitive_gma'
  )
  ORDER BY s.is_current ASC, s.activated_at DESC
  LIMIT 1;

  RETURN COALESCE(v_inferred, public.hiregauge_gma_current_set(v_agency));
END;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_gma_norm_facet(p_base text, p_set_key text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
-- Norm row for a base facet ('gma' or 'gma_speed') and an item set: the
-- plain facet name for the current set, '<facet>@<set>' for a retired set.
-- A local norm describes ONE item set (Nunnally & Bernstein 1994;
-- AERA/APA/NCME Standards 2014) -- never pool completions across sets.
DECLARE
  v_current boolean;
BEGIN
  IF p_set_key IS NULL THEN RETURN p_base; END IF;
  SELECT is_current INTO v_current FROM public.hiregauge_gma_item_sets WHERE set_key = p_set_key;
  IF v_current IS NULL OR v_current THEN RETURN p_base; END IF;
  RETURN p_base || '@' || p_set_key;
END;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_gma_items_for_candidate(p_candidate_id uuid)
 RETURNS SETOF public.hiregauge_instrument_items
 LANGUAGE sql
 STABLE
AS $function$
  -- Every GMA item in the candidate's set, active or not, in item order.
  -- Serving reads THIS, never is_active, so a set change never re-serves or
  -- truncates a sitting already in progress.
  SELECT i.*
  FROM public.hiregauge_gma_item_set_members m
  JOIN public.hiregauge_instrument_items i ON i.id = m.item_id
  WHERE m.set_key = public.hiregauge_gma_candidate_set(p_candidate_id)
  ORDER BY i.item_number;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_gma_accept_item(p_candidate_id uuid, p_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
-- Called by the v1-assessment edge function before saving a GMA answer.
-- Accepts the item if it belongs to the candidate's set and locks the set on
-- the first accepted answer. Race handling: a candidate served the previous
-- set moments before a flip may post their first GMA answer after it -- if
-- they have answered no GMA item yet and the item belongs to a retired set,
-- they are locked to that set (the one actually on their screen).
DECLARE
  v_locked text;
  v_set text;
  v_n_resp int;
  v_member_set text;
BEGIN
  SELECT gma_item_set INTO v_locked FROM public.hiring_candidates WHERE id = p_candidate_id;
  v_set := COALESCE(v_locked, public.hiregauge_gma_candidate_set(p_candidate_id));

  IF EXISTS (SELECT 1 FROM public.hiregauge_gma_item_set_members WHERE set_key = v_set AND item_id = p_item_id) THEN
    IF v_locked IS NULL THEN
      UPDATE public.hiring_candidates SET gma_item_set = v_set
      WHERE id = p_candidate_id AND gma_item_set IS NULL;
    END IF;
    RETURN jsonb_build_object('accepted', true, 'set_key', v_set, 'locked_now', v_locked IS NULL);
  END IF;

  IF v_locked IS NULL THEN
    SELECT count(*)::int INTO v_n_resp
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id AND i.section = 'newtworks_v2_cognitive_gma';
    IF v_n_resp = 0 THEN
      SELECT m.set_key INTO v_member_set
      FROM public.hiregauge_gma_item_set_members m
      JOIN public.hiregauge_gma_item_sets s ON s.set_key = m.set_key
      WHERE m.item_id = p_item_id
      ORDER BY s.is_current DESC, s.activated_at DESC
      LIMIT 1;
      IF v_member_set IS NOT NULL THEN
        UPDATE public.hiring_candidates SET gma_item_set = v_member_set
        WHERE id = p_candidate_id AND gma_item_set IS NULL;
        RETURN jsonb_build_object('accepted', true, 'set_key', v_member_set, 'locked_now', true,
                                  'note', 'locked to the set the item belongs to (served before a set change)');
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('accepted', false, 'set_key', v_set, 'reason', 'item_not_in_candidate_item_set');
END;
$function$;

REVOKE ALL ON FUNCTION public.hiregauge_gma_current_set(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hiregauge_gma_candidate_set(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hiregauge_gma_norm_facet(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hiregauge_gma_items_for_candidate(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hiregauge_gma_accept_item(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_current_set(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_candidate_set(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_norm_facet(text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_items_for_candidate(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_accept_item(uuid, uuid) TO authenticated, service_role;
