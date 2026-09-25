-- Signed-in logins run the fine rule (the Fines tab reads family_fine_kids; the family_ledger
-- trigger calls family_fine_applies as whoever gives the fine). Same grants as the other family_* functions.
GRANT EXECUTE ON FUNCTION public.family_fine_applies(uuid, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_fine_kids(date) TO authenticated;

