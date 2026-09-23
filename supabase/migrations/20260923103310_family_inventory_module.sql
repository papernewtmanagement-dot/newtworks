-- Household inventory for the Family area: the master shopping list, "Running low" taps
-- with a dancing character, and a learned expectation of how fast each item gets used.
-- Same access as everything under the Family divider: site admins + the family login.

CREATE TABLE IF NOT EXISTS public.family_inventory_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  name text NOT NULL CHECK (btrim(name) <> ''),
  amount numeric NOT NULL CHECK (amount > 0),
  unit text,
  every_days numeric NOT NULL CHECK (every_days > 0),
  learning_since timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.family_inventory_items IS
  'Master shopping list for stocking the house. amount = how much is bought each time (in unit); every_days = how often the family expects to buy it. Those two are the preset. learning_since = when the site started learning from real use; it resets whenever the preset is changed.';

CREATE UNIQUE INDEX IF NOT EXISTS family_inventory_items_name_key
  ON public.family_inventory_items (agency_id, lower(btrim(name)));

CREATE TABLE IF NOT EXISTS public.family_inventory_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seq bigint GENERATED ALWAYS AS IDENTITY,
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  item_id uuid NOT NULL REFERENCES public.family_inventory_items(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('start', 'low', 'ordered', 'left')),
  qty numeric CHECK (qty IS NULL OR qty >= 0),
  dancer text,
  at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);
COMMENT ON TABLE public.family_inventory_events IS
  'What happened to each inventory item, in order. start = one usual amount assumed on hand when the item was added. low = someone tapped Running low (dancer = the character dancing next to it). ordered = a parent marked it ordered (qty = how much). left = a parent said it is not out yet (qty = how much is still on hand). family_inventory_board() reads this log; no running total is stored anywhere.';

CREATE INDEX IF NOT EXISTS family_inventory_events_item_idx
  ON public.family_inventory_events (item_id, at, seq);

-- ── Triggers ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.family_inventory_item_added()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- A new item starts as if one usual amount was just bought.
  INSERT INTO public.family_inventory_events (agency_id, item_id, kind, qty, at)
  VALUES (NEW.agency_id, NEW.id, 'start', NEW.amount, NEW.created_at);
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS family_inventory_item_added ON public.family_inventory_items;
CREATE TRIGGER family_inventory_item_added
  AFTER INSERT ON public.family_inventory_items
  FOR EACH ROW EXECUTE FUNCTION public.family_inventory_item_added();

CREATE OR REPLACE FUNCTION public.family_inventory_item_changed()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  NEW.updated_at := now();
  -- A new amount or schedule is a new expectation: learning starts over from it.
  IF NEW.amount IS DISTINCT FROM OLD.amount OR NEW.every_days IS DISTINCT FROM OLD.every_days THEN
    NEW.learning_since := now();
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS family_inventory_item_changed ON public.family_inventory_items;
CREATE TRIGGER family_inventory_item_changed
  BEFORE UPDATE ON public.family_inventory_items
  FOR EACH ROW EXECUTE FUNCTION public.family_inventory_item_changed();

-- ── The board: the only place anything about an item is worked out ────────
CREATE OR REPLACE FUNCTION public.family_inventory_board()
RETURNS TABLE (
  item_id uuid,
  name text,
  amount numeric,
  unit text,
  every_days numeric,
  lasts_days numeric,
  measured integer,
  is_low boolean,
  low_at timestamptz,
  dancer text,
  days_left numeric,
  out_on date,
  likely_out boolean,
  suggested_qty numeric,
  last_ordered_at timestamptz
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
#variable_conflict use_column
-- DESIGN RECORD (2026-09-23, Peter's spec: preset how much and how often, then learn
-- from real use so the expectation adjusts week to week).
--
-- 1. What is learned is the RATE of use (units per day). How long one usual amount lasts
--    (lasts_days) is amount / rate. A rate stays right when the family buys more or less
--    than usual one week; a learned "how often" would not.
-- 2. The rate comes from the stock balance between two points where the stock level is
--    known: used = stock at the start + everything bought since - stock at the end.
--    A Running low tap counts as the empty point. A parent's "still have some" answer
--    gives the level directly. An order with no tap before it is just stock added, so
--    ordering early never teaches the site anything false.
-- 3. The days between a Running low tap and the next order are left out of the window.
--    Time spent out of stock shows nothing about use (Nahmias 1994, Demand estimation in
--    lost sales inventory systems, Naval Research Logistics 41(6), 739-757), so the
--    window restarts at the order.
-- 4. rate = discounted total used / discounted total days. For steady use, total used over
--    total time is the maximum-likelihood rate (Cox & Lewis 1966, The Statistical Analysis
--    of Series of Events). Dividing two smoothed totals, as Croston (1972, Forecasting and
--    stock control for intermittent demands, Operational Research Quarterly 23(3), 289-303)
--    smooths size and interval separately, avoids the bias of averaging each window's own
--    rate, and lets a long window count for more than a short one.
-- 5. Every older window is discounted by (1 - alpha) each time a new one lands:
--    exponential smoothing (Brown 1959, Statistical Forecasting for Inventory Control).
--    alpha = 0.3, the responsive end of the 0.1-0.3 range the literature reports in
--    practice (Gardner 2006, Exponential smoothing: The state of the art Part II,
--    International Journal of Forecasting 22(4), 637-666), because a household's use
--    shifts with seasons and growing kids and each item only gets a few measurements.
-- 6. The preset counts as one measured window of amount over every_days. It is the whole
--    answer until real data arrives and fades as windows land (0.7, 0.49, 0.34 ...).
--    Changing the preset sets learning_since; only windows that start after it count.
-- 7. The starting stock when an item is added is a guess (one usual amount on hand). It
--    sets the first countdown but never enters the rate. Learning starts at the first
--    window whose starting stock is known: an order right after a Running low tap, or a
--    parent's "still have some" answer.
-- 8. Before a window enters, its rate is held within 3x either side of the current
--    estimate, so one mistaken tap cannot swing the expectation. This is the clipping
--    idea of robust exponential smoothing (Gelper, Fried & Croux 2010, Robust forecasting
--    with exponential and Holt-Winters smoothing, Journal of Forecasting 29(3), 285-300),
--    applied to a rate, where errors are multiplicative.
-- 9. Look-ahead is one week, the family's order cadence: likely_out = not tapped and
--    expected to run out within 7 days. suggested_qty = enough to last to the next
--    weekly order, never less than the usual amount, rounded up to a whole unit.
DECLARE
  c_alpha   constant numeric := 0.3;
  c_clip    constant numeric := 3;
  c_horizon constant numeric := 7;
  it record;
  ev record;
  w_used numeric;
  w_days numeric;
  n integer;
  a_at timestamptz;
  a_qty numeric;
  bought numeric;
  waiting boolean;
  a_known boolean;
  v_low_at timestamptz;
  v_dancer text;
  v_ordered timestamptz;
  v_rate numeric;
  v_left numeric;
  v_span numeric;
  v_used numeric;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  FOR it IN
    SELECT i.* FROM public.family_inventory_items i
    WHERE i.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    ORDER BY lower(i.name)
  LOOP
    w_used := it.amount; w_days := it.every_days; n := 0;
    a_at := NULL; a_qty := 0; bought := 0; waiting := false; a_known := false;
    v_low_at := NULL; v_dancer := NULL; v_ordered := NULL;

    FOR ev IN
      SELECT e.kind, e.qty, e.at, e.dancer
      FROM public.family_inventory_events e
      WHERE e.item_id = it.id
      ORDER BY e.at, e.seq
    LOOP
      -- A tap or a level check closes a window with a known start that began after learning_since.
      IF ev.kind IN ('low', 'left') AND NOT waiting AND a_known AND a_at >= it.learning_since THEN
        v_span := extract(epoch FROM ev.at - a_at) / 86400.0;
        IF v_span > 0 THEN
          v_used := GREATEST(a_qty + bought - CASE WHEN ev.kind = 'left' THEN COALESCE(ev.qty, 0) ELSE 0 END, 0);
          v_rate := w_used / w_days;
          v_used := LEAST(GREATEST(v_used, v_span * v_rate / c_clip), v_span * v_rate * c_clip);
          w_used := w_used * (1 - c_alpha) + v_used;
          w_days := w_days * (1 - c_alpha) + v_span;
          n := n + 1;
        END IF;
      END IF;

      IF ev.kind = 'start' THEN
        a_at := ev.at; a_qty := COALESCE(ev.qty, 0); bought := 0; waiting := false; a_known := false;
      ELSIF ev.kind = 'ordered' THEN
        v_ordered := ev.at; v_low_at := NULL; v_dancer := NULL;
        IF waiting OR a_at IS NULL THEN
          a_known := waiting;  -- bought when it was running low: the start of this window is known
          a_at := ev.at; a_qty := COALESCE(ev.qty, 0); bought := 0; waiting := false;
        ELSE
          bought := bought + COALESCE(ev.qty, 0);
        END IF;
      ELSIF ev.kind = 'low' THEN
        waiting := true; a_at := NULL; a_qty := 0; bought := 0; a_known := false;
        v_low_at := ev.at; v_dancer := ev.dancer;
      ELSIF ev.kind = 'left' THEN
        a_at := ev.at; a_qty := COALESCE(ev.qty, 0); bought := 0; waiting := false; a_known := true;
        v_low_at := NULL; v_dancer := NULL;
      END IF;
    END LOOP;

    v_rate := w_used / w_days;

    IF waiting THEN
      v_left := 0;
    ELSIF a_at IS NULL THEN
      v_left := NULL;
    ELSE
      v_left := a_qty + bought - v_rate * extract(epoch FROM now() - a_at) / 86400.0;
    END IF;

    item_id := it.id;
    name := it.name;
    amount := it.amount;
    unit := it.unit;
    every_days := it.every_days;
    lasts_days := round(it.amount / v_rate, 2);
    measured := n;
    is_low := waiting;
    low_at := v_low_at;
    dancer := v_dancer;
    last_ordered_at := v_ordered;
    days_left := CASE WHEN v_left IS NULL THEN NULL ELSE round(v_left / v_rate, 2) END;
    out_on := CASE WHEN v_left IS NULL THEN NULL
                   ELSE ((now() + (GREATEST(v_left / v_rate, 0))::float8 * interval '1 day') AT TIME ZONE 'America/Chicago')::date END;
    likely_out := (NOT waiting) AND v_left IS NOT NULL AND v_left / v_rate <= c_horizon;
    suggested_qty := GREATEST(it.amount, ceil(v_rate * c_horizon - GREATEST(COALESCE(v_left, 0), 0)));
    RETURN NEXT;
  END LOOP;
END $function$;

-- ── Writers ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.family_inventory_mark_low(p_item_id uuid, p_dancer text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_last text;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  PERFORM 1 FROM public.family_inventory_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'That item is not on the list.'; END IF;
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
DECLARE v_last public.family_inventory_events;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  PERFORM 1 FROM public.family_inventory_items WHERE id = p_item_id FOR UPDATE;
  SELECT e.* INTO v_last FROM public.family_inventory_events e
  WHERE e.item_id = p_item_id ORDER BY e.at DESC, e.seq DESC LIMIT 1;
  IF v_last.kind = 'low' THEN
    DELETE FROM public.family_inventory_events WHERE id = v_last.id;
  END IF;
END $function$;

CREATE OR REPLACE FUNCTION public.family_inventory_mark_ordered(p_items jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v jsonb; v_id uuid; v_amount numeric; v_qty numeric; n integer := 0;
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can mark things ordered.'; END IF;
  FOR v IN SELECT x.value FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) AS x(value) LOOP
    v_id := NULLIF(v->>'item_id', '')::uuid;
    v_amount := NULL;
    SELECT i.amount INTO v_amount FROM public.family_inventory_items i WHERE i.id = v_id FOR UPDATE;
    IF v_amount IS NULL THEN RAISE EXCEPTION 'An item on this order is not on the list anymore.'; END IF;
    v_qty := COALESCE(NULLIF(v->>'qty', '')::numeric, v_amount);
    IF v_qty <= 0 THEN RAISE EXCEPTION 'Enter how much was ordered.'; END IF;
    INSERT INTO public.family_inventory_events (item_id, kind, qty) VALUES (v_id, 'ordered', v_qty);
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public.family_inventory_mark_left(p_item_id uuid, p_share numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- p_share = how much is still on hand, as a share of the usual amount (0.25 a little, 0.5 about half, 1 plenty).
DECLARE v_amount numeric;
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can say how much is left.'; END IF;
  IF p_share IS NULL OR p_share < 0 THEN RAISE EXCEPTION 'Pick how much is left.'; END IF;
  SELECT i.amount INTO v_amount FROM public.family_inventory_items i WHERE i.id = p_item_id FOR UPDATE;
  IF v_amount IS NULL THEN RAISE EXCEPTION 'That item is not on the list.'; END IF;
  -- Some is left, so an open Running low tap goes away first (same undo everyone uses).
  PERFORM public.family_inventory_unmark_low(p_item_id);
  INSERT INTO public.family_inventory_events (item_id, kind, qty)
  VALUES (p_item_id, 'left', round(v_amount * p_share, 3));
END $function$;

-- ── Access: parents do everything; the family login reads, and taps through the functions ──
ALTER TABLE public.family_inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_inventory_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS family_inventory_items_family_read ON public.family_inventory_items;
CREATE POLICY family_inventory_items_family_read ON public.family_inventory_items
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.auth_is_family()));

DROP POLICY IF EXISTS family_inventory_items_parents_all ON public.family_inventory_items;
CREATE POLICY family_inventory_items_parents_all ON public.family_inventory_items
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));

DROP POLICY IF EXISTS family_inventory_events_family_read ON public.family_inventory_events;
CREATE POLICY family_inventory_events_family_read ON public.family_inventory_events
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.auth_is_family()));

DROP POLICY IF EXISTS family_inventory_events_parents_all ON public.family_inventory_events;
CREATE POLICY family_inventory_events_parents_all ON public.family_inventory_events
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));

