-- Office inventory + team requests (Peter 2026-10-08).
-- The team gets an "Office" page: tap office supplies that are running low, request a snack,
-- and send prize cart ideas. Office items live in the same inventory table as the house,
-- marked by a location column; Alvi's Inventory > Admin tab shows Home and Office apart.
-- A snack request adds the snack to the office list (if new) and taps it Running low.
-- Prize cart ideas wait in prize_cart_ideas and go to Alvi with the quarter's prize cart close.

-- 1. Where an item is kept: the house or the office.
ALTER TABLE public.family_inventory_items ADD COLUMN IF NOT EXISTS location text NOT NULL DEFAULT 'home';
DO $$ BEGIN
  ALTER TABLE public.family_inventory_items
    ADD CONSTRAINT family_inventory_items_location_check CHECK (location IN ('home', 'office'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- The same name can be on both lists (paper towels at home and at the office).
DROP INDEX IF EXISTS public.family_inventory_items_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS family_inventory_items_name_key
  ON public.family_inventory_items (agency_id, location, lower(btrim(name)));

-- 2. Who may see and tap a list. Home: parents and the Family Hub login. Office: every agency login.
CREATE OR REPLACE FUNCTION public.inventory_can_use(p_location text)
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

