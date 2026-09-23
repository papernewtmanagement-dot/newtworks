-- Household inventory: keep the master list's store sections and order, and let
-- "how often" be blank. With no schedule the site predicts nothing for an item until
-- it has measured one real cycle from use.

ALTER TABLE public.family_inventory_items ADD COLUMN IF NOT EXISTS section text;
CREATE SEQUENCE IF NOT EXISTS public.family_inventory_items_sort_seq;
ALTER TABLE public.family_inventory_items
  ADD COLUMN IF NOT EXISTS sort_order bigint NOT NULL DEFAULT nextval('public.family_inventory_items_sort_seq');
ALTER SEQUENCE public.family_inventory_items_sort_seq OWNED BY public.family_inventory_items.sort_order;
ALTER TABLE public.family_inventory_items ALTER COLUMN every_days DROP NOT NULL;
ALTER TABLE public.family_inventory_items ALTER COLUMN amount SET DEFAULT 1;
COMMENT ON COLUMN public.family_inventory_items.section IS 'Store section the item is listed under (PRODUCE, MEAT ...). Sections show in the order of their first item.';
COMMENT ON COLUMN public.family_inventory_items.sort_order IS 'Position on the master list. New items take the next number, so they land at the end of their section.';
COMMENT ON COLUMN public.family_inventory_items.every_days IS 'How often the family expects to buy it, in days. NULL = not set; the site learns it from use.';

-- The board gains section and sort_order, so its return type changes and it must be
-- dropped and recreated. Guard: stop if any other database function calls it.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname <> 'family_inventory_board'
      AND pg_get_functiondef(p.oid) LIKE '%family_inventory_board(%'
  ) THEN
    RAISE EXCEPTION 'family_inventory_board has a database caller; update it before dropping.';
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.family_inventory_board();

CREATE FUNCTION public.family_inventory_board()
RETURNS TABLE (
  item_id uuid,
  section text,
  sort_order bigint,
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
--    No preset (every_days NULL) = no prior: nothing is predicted for the item until its
--    first measured window, which is taken as measured (there is nothing to clip against).
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
-- 10. Rows come back in master-list order: sections in the order of their first item,
--    items by sort_order inside a section.
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
    SELECT i.*, min(i.sort_order) OVER (PARTITION BY COALESCE(i.section, '')) AS sec_order
    FROM public.family_inventory_items i
    WHERE i.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    ORDER BY sec_order, i.sort_order, lower(i.name)
  LOOP
    IF it.every_days IS NULL THEN
      w_used := 0; w_days := 0;
    ELSE
      w_used := it.amount; w_days := it.every_days;
    END IF;
    n := 0;
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
          v_rate := CASE WHEN w_days > 0 AND w_used > 0 THEN w_used / w_days END;
          IF v_rate IS NOT NULL THEN
            v_used := LEAST(GREATEST(v_used, v_span * v_rate / c_clip), v_span * v_rate * c_clip);
          END IF;
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

    v_rate := CASE WHEN w_days > 0 AND w_used > 0 THEN w_used / w_days END;

    IF waiting THEN
      v_left := 0;
    ELSIF a_at IS NULL OR v_rate IS NULL THEN
      v_left := NULL;
    ELSE
      v_left := a_qty + bought - v_rate * extract(epoch FROM now() - a_at) / 86400.0;
    END IF;

    item_id := it.id;
    section := it.section;
    sort_order := it.sort_order;
    name := it.name;
    amount := it.amount;
    unit := it.unit;
    every_days := it.every_days;
    lasts_days := CASE WHEN v_rate IS NULL THEN NULL ELSE round(it.amount / v_rate, 2) END;
    measured := n;
    is_low := waiting;
    low_at := v_low_at;
    dancer := v_dancer;
    last_ordered_at := v_ordered;
    days_left := CASE WHEN waiting THEN 0 WHEN v_left IS NULL THEN NULL ELSE round(v_left / v_rate, 2) END;
    out_on := CASE WHEN waiting THEN (now() AT TIME ZONE 'America/Chicago')::date
                   WHEN v_left IS NULL THEN NULL
                   ELSE ((now() + (GREATEST(v_left / v_rate, 0))::float8 * interval '1 day') AT TIME ZONE 'America/Chicago')::date END;
    likely_out := (NOT waiting) AND v_left IS NOT NULL AND v_left / v_rate <= c_horizon;
    suggested_qty := CASE WHEN v_rate IS NULL THEN it.amount
                          ELSE GREATEST(it.amount, ceil(v_rate * c_horizon - GREATEST(COALESCE(v_left, 0), 0))) END;
    RETURN NEXT;
  END LOOP;
END $function$;

-- New functions get EXECUTE for PUBLIC by default; the board is for logged-in people only.
REVOKE EXECUTE ON FUNCTION public.family_inventory_board() FROM PUBLIC, anon;

