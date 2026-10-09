-- Peter 2026-10-08 (follow-up): only teammates listed as working in the office can use the
-- office list (tap Running low, request snacks). Everyone can still send prize cart ideas.
-- The office list starts from the admin manual's "Supply-Stocking Process" page, word for word,
-- and that page is deleted from the manual.

-- 1. Who stocks the office: admins, and active teammates whose work location is in the office.
CREATE OR REPLACE FUNCTION public.office_can_stock()
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.is_agency_admin()
      OR EXISTS (SELECT 1 FROM public.team t
                 WHERE t.id = public.current_team_member_id()
                   AND t.work_location = 'in_office'
                   AND t.is_active AND t.archived_at IS NULL);
$function$;

CREATE OR REPLACE FUNCTION public.inventory_can_use(p_location text)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT CASE p_location
    WHEN 'home'   THEN public.family_is_parent() OR public.auth_is_family()
    WHEN 'office' THEN public.office_can_stock()
    ELSE false END;
$function$;

-- 2. Snack requests sit with the other kitchen supplies.
CREATE OR REPLACE FUNCTION public.office_request_snack(p_name text, p_dancer text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_name text := btrim(COALESCE(p_name, '')); v_id uuid;
BEGIN
  PERFORM public.require_login('staff');
  IF NOT public.inventory_can_use('office') THEN RAISE EXCEPTION 'Snack requests are for teammates working in the office.'; END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'Type the snack you want.'; END IF;
  IF length(v_name) > 80 THEN RAISE EXCEPTION 'Keep the snack name short.'; END IF;
  SELECT id INTO v_id FROM public.family_inventory_items
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND location = 'office' AND lower(btrim(name)) = lower(v_name);
  IF v_id IS NULL THEN
    INSERT INTO public.family_inventory_items (agency_id, name, section, location, amount)
    VALUES ('126794dd-25ff-47d2-a436-724499733365'::uuid, v_name, 'Kitchen Supplies', 'office', 1)
    RETURNING id INTO v_id;
  END IF;
  PERFORM public.family_inventory_mark_low(v_id, p_dancer);
  RETURN v_id;
END $function$;

REVOKE EXECUTE ON FUNCTION public.office_can_stock() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.office_can_stock() TO authenticated, service_role;

-- 3. The office list, from the Supply-Stocking Process page, in its order. One of each; how often is learned from use.
INSERT INTO public.family_inventory_items (agency_id, name, section, location, amount)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid, v.name, v.section, 'office', 1
FROM (VALUES
  (1, 'Office Supplies', 'Notepads'),
  (2, 'Office Supplies', 'Pens'),
  (3, 'Office Supplies', 'Sharpies - Regular'),
  (4, 'Office Supplies', 'Stamps'),
  (5, 'Office Supplies', 'Envelopes'),
  (6, 'Office Supplies', 'Scissors'),
  (7, 'Office Supplies', 'Paper Clips'),
  (8, 'Office Supplies', 'Paper Clamps'),
  (9, 'Office Supplies', 'Garbage Bags'),
  (10, 'Office Supplies', 'Small Trash Bags'),
  (11, 'Kitchen Supplies', 'Water - Single Serve'),
  (12, 'Kitchen Supplies', 'Napkins'),
  (13, 'Kitchen Supplies', 'Paper Plates'),
  (14, 'Kitchen Supplies', 'Disposable Cups'),
  (15, 'Kitchen Supplies', 'Disposable Forks'),
  (16, 'Kitchen Supplies', 'Disposable Spoons'),
  (17, 'Kitchen Supplies', 'Disposable Knives'),
  (18, 'Kitchen Supplies', 'Coffee'),
  (19, 'Kitchen Supplies', 'Tea'),
  (20, 'Kitchen Supplies', 'Sugar'),
  (21, 'Kitchen Supplies', 'Stir Sticks'),
  (22, 'Kitchen Supplies', 'Coffee Filters'),
  (23, 'Kitchen Supplies', 'Snacks'),
  (24, 'Kitchen Supplies', 'Soda'),
  (25, 'Bathroom Supplies', 'Paper Towels'),
  (26, 'Bathroom Supplies', 'Toilet Paper'),
  (27, 'Bathroom Supplies', 'Hand Soap'),
  (28, 'Bathroom Supplies', 'Clorox Wipes'),
  (29, 'Bathroom Supplies', 'Wet Wipes'),
  (30, 'Bathroom Supplies', 'Hand Sanitizer'),
  (31, 'Bathroom Supplies', 'Toilet Scrubber Refills'),
  (32, 'Bathroom Supplies', 'Printer Ink - Check Both Printers'),
  (33, 'Organize and restock marketing closet - order through AOC', 'Brochures and Pamphlets'),
  (34, 'Organize and restock marketing closet - order through AOC', 'Promotional Items'),
  (35, 'Organize and restock marketing closet - order through AOC', 'Welcome Binders'),
  (36, 'Organize and restock marketing closet - order through AOC', 'Welcome Folders')
) AS v(ord, section, name)
WHERE NOT EXISTS (SELECT 1 FROM public.family_inventory_items i
                  WHERE i.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
                    AND i.location = 'office' AND lower(btrim(i.name)) = lower(v.name))
ORDER BY v.ord;

-- 4. The Background page pointed at that page; it now points at the office list instead.
UPDATE public.manuals
SET content = replace(content, '*[Embedded excerpt from: Supply-Stocking Process]*',
                      'Restock from the office list on the Requests page. Tap anything running low.'),
    updated_at = now()
WHERE id = 'ca344d8e-a5bd-4e4a-a4b1-afdd1536e870'
  AND content LIKE '%*[Embedded excerpt from: Supply-Stocking Process]*%';

-- 5. Delete the Supply-Stocking Process page from the manual (Peter's instruction).
DELETE FROM public.manuals WHERE id = '1b2c18f0-84eb-4a4e-bd19-a1f2cdfe9e47' AND title = 'Supply-Stocking Process';

