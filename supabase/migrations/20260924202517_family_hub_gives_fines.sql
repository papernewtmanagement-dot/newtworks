-- Family: the hub login can give fines from a kid's page (Peter 2026-09-24: "add fines from the kid's
-- individual page, through the hub user account"). Only fines from the fine list, at the list price.
-- Who can get which fine is still checked by the family_ledger_fine_fits trigger. The hub still cannot
-- delete or change a fine (no update or delete policy for it); parents undo.
ALTER POLICY family_ledger_family_insert ON public.family_ledger
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND (SELECT public.auth_is_family())
    AND (kind = 'expense'
         OR (kind = 'fine'
             AND fine_type_id IS NOT NULL
             AND amount = -(SELECT t.amount FROM public.family_fine_types t
                            WHERE t.id = family_ledger.fine_type_id AND t.is_active)))
  );

