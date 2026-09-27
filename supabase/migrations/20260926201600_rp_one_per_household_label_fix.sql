-- The household label of a sale held in a variable is read with customer_label(s); s.customer_label only
-- works on a table alias.
DO $migrate$
DECLARE d text; old text := 'AND os.customer_label = s.customer_label'; new text := 'AND os.customer_label = public.customer_label(s)'; n integer;
BEGIN
  d := pg_get_functiondef('public.rp_replace_one_per_household(uuid)'::regprocedure);
  n := (length(d) - length(replace(d, old, ''))) / length(old);
  IF n <> 1 THEN RAISE EXCEPTION 'rp_replace_one_per_household: label text found % times', n; END IF;
  EXECUTE replace(d, old, new);
END $migrate$;
REVOKE ALL ON FUNCTION public.rp_replace_one_per_household(uuid) FROM PUBLIC, anon, authenticated;
