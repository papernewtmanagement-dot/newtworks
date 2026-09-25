-- Family: a fine can be tied to a chore checklist, so it only goes to kids who do that chore.
-- Peter 2026-09-24: "Add a $2 fine for dish not washed for anyone who has a chore of dishes."

ALTER TABLE public.family_fine_types
  ADD COLUMN IF NOT EXISTS chore_checklist_id uuid REFERENCES public.family_checklists(id);

COMMENT ON COLUMN public.family_fine_types.chore_checklist_id IS
  'Only kids with an active chore that uses this checklist can get this fine. NULL = any kid. Rule: family_fine_applies().';

-- The one rule for who can get a fine.
CREATE OR REPLACE FUNCTION public.family_fine_applies(p_fine_type_id uuid, p_kid_id uuid, p_on date DEFAULT ((now() AT TIME ZONE 'America/Chicago'::text))::date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- A fine with no chore checklist goes to any kid. A fine tied to a checklist goes only to a kid
  -- who has a chore using that checklist, active on p_on (Peter 2026-09-24: Dish not washed is
  -- for anyone who has a dishes chore).
  SELECT EXISTS (
    SELECT 1 FROM public.family_fine_types t
    WHERE t.id = p_fine_type_id
      AND (t.chore_checklist_id IS NULL
           OR EXISTS (SELECT 1 FROM public.family_chores c
                      WHERE c.kid_id = p_kid_id
                        AND c.checklist_id = t.chore_checklist_id
                        AND c.active_from <= p_on
                        AND (c.active_to IS NULL OR c.active_to >= p_on)))
  );
$function$;

-- Every kid and fine pair that fits on a day. The Fines tab reads this; it never works the rule out itself.
CREATE OR REPLACE FUNCTION public.family_fine_kids(p_on date DEFAULT ((now() AT TIME ZONE 'America/Chicago'::text))::date)
 RETURNS TABLE(fine_type_id uuid, kid_id uuid)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT t.id, k.id
  FROM public.family_fine_types t
  CROSS JOIN public.family_kids k
  WHERE t.is_active AND k.is_active
    AND public.family_fine_applies(t.id, k.id, p_on);
$function$;

-- A fine given from the list must fit the kid. Fines with no fine type (shower, missed chores) pass.
CREATE OR REPLACE FUNCTION public.family_ledger_fine_fits()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_name text;
  v_chore text;
BEGIN
  IF NOT public.family_fine_applies(NEW.fine_type_id, NEW.kid_id, NEW.entry_date) THEN
    SELECT t.name, cl.name INTO v_name, v_chore
    FROM public.family_fine_types t
    LEFT JOIN public.family_checklists cl ON cl.id = t.chore_checklist_id
    WHERE t.id = NEW.fine_type_id;
    RAISE EXCEPTION '% is only for kids who do %.', COALESCE(v_name, 'That fine'), COALESCE(v_chore, 'that chore');
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS family_ledger_fine_fits ON public.family_ledger;
CREATE TRIGGER family_ledger_fine_fits
  BEFORE INSERT OR UPDATE OF kid_id, fine_type_id, entry_date ON public.family_ledger
  FOR EACH ROW WHEN (NEW.kind = 'fine' AND NEW.fine_type_id IS NOT NULL)
  EXECUTE FUNCTION public.family_ledger_fine_fits();

-- Peter's fine: Dish not washed, $2, for kids who do Dishes (breakfast/lunch/dinner).
INSERT INTO public.family_fine_types (agency_id, name, amount, sort_order, chore_checklist_id)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Dish not washed', 2.00,
       COALESCE((SELECT max(sort_order) FROM public.family_fine_types WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'), 0) + 1,
       'dfa6f676-a3af-4ed8-8f44-f5f6bf35a114'
WHERE NOT EXISTS (SELECT 1 FROM public.family_fine_types
                  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND name = 'Dish not washed');

