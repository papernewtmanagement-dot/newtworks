-- Peter 2026-10-08: every quarter Claude shops the prize cart, Alvi reviews it on
-- Inventory > Admin > Prize cart (name, link, price, with a running total against the budget),
-- edits what she wants, and approves it. Shopped items wait as "proposed" and can't be drawn
-- until she approves. Her Telegram at quarter close is now the shopped cart for approval
-- (prize_cart_send_for_approval), sent by the shopping run, not the close itself.

-- 1. Shopped items wait for Alvi's approval.
ALTER TABLE public.prize_cart ADD COLUMN IF NOT EXISTS proposed boolean NOT NULL DEFAULT false;

-- 2. A proposed item can't be drawn.
DO $$
DECLARE v_def text; v_old text;
BEGIN
  v_def := pg_get_functiondef('public.record_mvp_prize_draw(uuid,date,uuid)'::regprocedure);
  v_old := $o$  WHERE c.id = p_prize_cart_id
    AND c.agency_id = v_agency
    AND c.winner_team_member_id IS NULL;$o$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'record_mvp_prize_draw: cart check not found'; END IF;
  EXECUTE replace(v_def, v_old, $n$  WHERE c.id = p_prize_cart_id
    AND c.agency_id = v_agency
    AND c.winner_team_member_id IS NULL
    AND NOT c.proposed;$n$);
END $$;

-- 3. The quarter's cart: who it's for, the budget, every item, and the totals. One place the math lives.
CREATE OR REPLACE FUNCTION public.prize_cart_review()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency constant uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_q date;
  v_label text;
  v_budget numeric;
  v_items jsonb;
  v_total numeric;
  v_unpriced int;
  v_proposed int;
BEGIN
  PERFORM public.require_login('admin');
  SELECT c.cycle_end, c.quarter_label INTO v_q, v_label
  FROM public.current_cycle_info(v_agency, (now() AT TIME ZONE 'America/Chicago')::date) c;

  SELECT b.budget_dollars INTO v_budget FROM public.quarter_prize_budgets b
  WHERE b.agency_id = v_agency AND b.quarter_ending_date = v_q;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', p.id, 'slot', p.display_order, 'name', p.prize_description, 'url', p.prize_url,
           'price', p.prize_value, 'proposed', p.proposed, 'new', p.is_new_this_quarter,
           'won', p.winner_team_member_id IS NOT NULL,
           'drawn', EXISTS (SELECT 1 FROM public.mvp_prize_draws d WHERE d.prize_cart_id = p.id))
           ORDER BY p.display_order), '[]'::jsonb),
         COALESCE(sum(p.prize_value), 0),
         count(*) FILTER (WHERE p.prize_value IS NULL),
         count(*) FILTER (WHERE p.proposed)
    INTO v_items, v_total, v_unpriced, v_proposed
  FROM public.prize_cart p
  WHERE p.agency_id = v_agency AND p.quarter_ending_date = v_q;

  RETURN jsonb_build_object(
    'quarter_ending_date', v_q, 'quarter_label', v_label,
    'budget', v_budget, 'total', round(v_total, 2),
    'remaining', CASE WHEN v_budget IS NULL THEN NULL ELSE round(v_budget - v_total, 2) END,
    'slots', 13, 'unpriced', v_unpriced, 'proposed', v_proposed, 'items', v_items);
END $function$;

-- 4. Add or edit one item. New items are proposed until the cart is approved.
CREATE OR REPLACE FUNCTION public.prize_cart_item_save(p_id uuid, p_name text, p_url text, p_price numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency constant uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_q date; v_slot int; v_id uuid;
  v_name text := btrim(COALESCE(p_name, ''));
  v_url text := NULLIF(btrim(COALESCE(p_url, '')), '');
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.role() IS NOT NULL THEN
    PERFORM public.require_login('admin');
  END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'Give the prize a name.'; END IF;
  IF p_price IS NOT NULL AND p_price < 0 THEN RAISE EXCEPTION 'The price can''t be negative.'; END IF;
  IF v_url IS NOT NULL AND v_url !~* '^https?://' THEN v_url := 'https://' || v_url; END IF;

  IF p_id IS NOT NULL THEN
    UPDATE public.prize_cart
       SET prize_description = v_name, prize_url = v_url, prize_value = round(p_price, 2), updated_at = now()
     WHERE id = p_id AND agency_id = v_agency AND winner_team_member_id IS NULL
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'That prize was already won or is gone.'; END IF;
    RETURN v_id;
  END IF;

  SELECT c.cycle_end INTO v_q FROM public.current_cycle_info(v_agency, (now() AT TIME ZONE 'America/Chicago')::date) c;
  SELECT min(s) INTO v_slot FROM generate_series(1, 13) s
  WHERE NOT EXISTS (SELECT 1 FROM public.prize_cart p WHERE p.agency_id = v_agency AND p.quarter_ending_date = v_q AND p.display_order = s);
  IF v_slot IS NULL THEN RAISE EXCEPTION 'The cart already has 13 prizes. Remove one first.'; END IF;

  INSERT INTO public.prize_cart (agency_id, quarter_ending_date, display_order, prize_description, prize_url, prize_value, is_new_this_quarter, proposed)
  VALUES (v_agency, v_q, v_slot, v_name, v_url, round(p_price, 2), true, true)
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;

-- 5. Take an item out of the cart, unless someone already drew or won it.
CREATE OR REPLACE FUNCTION public.prize_cart_item_remove(p_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.require_login('admin');
  IF EXISTS (SELECT 1 FROM public.mvp_prize_draws d WHERE d.prize_cart_id = p_id)
     OR EXISTS (SELECT 1 FROM public.prize_cart p WHERE p.id = p_id AND p.winner_team_member_id IS NOT NULL) THEN
    RAISE EXCEPTION 'Someone already drew or won that prize, so it stays.';
  END IF;
  DELETE FROM public.prize_cart WHERE id = p_id AND agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid;
END $function$;

-- 6. Alvi approves the cart: every proposed item becomes drawable.
CREATE OR REPLACE FUNCTION public.prize_cart_approve()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_q date; n int;
BEGIN
  PERFORM public.require_login('admin');
  SELECT c.cycle_end INTO v_q FROM public.current_cycle_info('126794dd-25ff-47d2-a436-724499733365'::uuid, (now() AT TIME ZONE 'America/Chicago')::date) c;
  UPDATE public.prize_cart SET proposed = false, updated_at = now()
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND quarter_ending_date = v_q AND proposed;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

-- 7. Alvi's Telegram: the shopped cart for her approval, the totals, and the team's ideas still on the list.
--    Called by the quarterly shopping run once the cart is filled. New ideas are stamped sent only when it goes out.
CREATE OR REPLACE FUNCTION public.prize_cart_send_for_approval()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_agency constant uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_q date; v_label text; v_budget numeric; v_total numeric;
  v_lines text; v_ideas text; v_idea_ids uuid[];
  v_chat bigint; v_text text; v_res jsonb;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.role() IS NOT NULL THEN
    PERFORM public.require_login('admin');
  END IF;
  SELECT c.cycle_end, c.quarter_label INTO v_q, v_label FROM public.current_cycle_info(v_agency, (now() AT TIME ZONE 'America/Chicago')::date) c;
  SELECT b.budget_dollars INTO v_budget FROM public.quarter_prize_budgets b WHERE b.agency_id = v_agency AND b.quarter_ending_date = v_q;

  SELECT string_agg(
           '• ' || p.prize_description || ' — ' || COALESCE('$' || to_char(p.prize_value, 'FM999990.00'), 'no price')
           || CASE WHEN p.proposed THEN '' ELSE ' (carried over)' END,
           chr(10) ORDER BY p.display_order),
         COALESCE(sum(p.prize_value), 0)
    INTO v_lines, v_total
  FROM public.prize_cart p WHERE p.agency_id = v_agency AND p.quarter_ending_date = v_q;

  SELECT array_agg(i.id ORDER BY i.created_at) FILTER (WHERE i.sent_at IS NULL),
         string_agg('• ' || CASE WHEN i.sent_at IS NULL THEN 'NEW: ' ELSE '' END || i.idea
                    || COALESCE(' (' || COALESCE(NULLIF(t.nickname, ''), t.first_name) || ')', ''), chr(10) ORDER BY i.created_at)
    INTO v_idea_ids, v_ideas
  FROM public.prize_cart_ideas i LEFT JOIN public.team t ON t.id = i.team_member_id
  WHERE i.agency_id = v_agency AND i.used_at IS NULL;

  SELECT telegram_user_id INTO v_chat FROM public.team
  WHERE agency_id = v_agency AND nickname = 'Alvi' AND telegram_user_id IS NOT NULL LIMIT 1;
  IF v_chat IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no Telegram on file for Alvi'); END IF;

  v_text := '🛒 ' || v_label || ' prize cart is shopped and ready for you' || chr(10) || chr(10)
    || COALESCE(v_lines, 'The cart is empty.') || chr(10) || chr(10)
    || 'Total: $' || to_char(v_total, 'FM999990.00')
    || COALESCE(' of $' || to_char(v_budget, 'FM999990.00') || ' budget ($' || to_char(v_budget - v_total, 'FM999990.00') || ' left)', '') || chr(10) || chr(10)
    || 'Change anything you want, then tap Approve: https://newtworks.vercel.app/inventory?tab=admin&place=prize'
    || CASE WHEN v_ideas IS NULL THEN '' ELSE chr(10) || chr(10) || 'Team ideas still on the list:' || chr(10) || v_ideas END;

  v_res := public.paper_newt_send_message(v_chat, v_text, NULL, NULL);
  IF COALESCE(v_res->>'ok', 'true') = 'false' THEN
    RETURN jsonb_build_object('ok', false, 'error', COALESCE(v_res->>'description', v_res::text));
  END IF;
  IF v_idea_ids IS NOT NULL THEN
    UPDATE public.prize_cart_ideas SET sent_at = now() WHERE id = ANY (v_idea_ids);
  END IF;
  RETURN jsonb_build_object('ok', true, 'quarter', v_label, 'total', v_total, 'budget', v_budget, 'new_ideas_sent', COALESCE(cardinality(v_idea_ids), 0));
END $function$;

REVOKE EXECUTE ON FUNCTION public.prize_cart_review() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_item_save(uuid, text, text, numeric) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_item_remove(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_approve() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.prize_cart_send_for_approval() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prize_cart_review() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_item_save(uuid, text, text, numeric) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_item_remove(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_approve() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prize_cart_send_for_approval() TO authenticated, service_role;

-- 8. Quarter close: carry only approved, unwon prizes. Alvi's message now comes from the shopping run
--    (prize_cart_send_for_approval), so the close only tells Peter the budget.
DO $$
DECLARE v_def text; v_old text; v_start int; v_end int;
BEGIN
  v_def := pg_get_functiondef('public.quarter_close_prize_cart_and_leaderboards(uuid,date)'::regprocedure);

  v_old := $o$      AND winner_team_member_id IS NULL
    RETURNING prize_value$o$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'close: carry filter not found'; END IF;
  v_def := replace(v_def, v_old, $n$      AND winner_team_member_id IS NULL AND NOT proposed
    RETURNING prize_value$n$);

  v_start := position('  -- Alvi gets the same refresh' in v_def);
  v_end := position('  v_result := jsonb_build_object(' in v_def);
  IF v_start = 0 OR v_end = 0 OR v_end < v_start THEN RAISE EXCEPTION 'close: Alvi block not found'; END IF;
  v_def := substr(v_def, 1, v_start - 1)
        || '  -- Alvi''s message comes from the quarterly shopping run (prize_cart_send_for_approval).' || chr(10) || chr(10)
        || substr(v_def, v_end);

  v_old := $o$    'new_prize_ideas_sent', COALESCE(cardinality(v_idea_ids), 0), 'alvi_message', v_alvi_status,
$o$;
  IF position(v_old in v_def) = 0 THEN RAISE EXCEPTION 'close: result keys not found'; END IF;
  v_def := replace(v_def, v_old, '');

  EXECUTE v_def;
END $$;
