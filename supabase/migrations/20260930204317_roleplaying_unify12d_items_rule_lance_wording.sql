-- roleplaying_unify12d_items_rule_lance_wording
-- Defect in unify12c's rule text, found in the rolled-back test: a lance is swung with the Lance skill, not Spear.
DO $do$
DECLARE v text; n integer;
BEGIN
  SELECT body INTO v FROM public.rpg_rules WHERE key = 'items';
  n := (length(v) - length(replace(v, 'a lance is 6 over, so his Spear 5 rolls as 0', ''))) / length('a lance is 6 over, so his Spear 5 rolls as 0');
  IF n <> 1 THEN RAISE EXCEPTION 'items rule anchor found % times', n; END IF;
  UPDATE public.rpg_rules SET body = replace(v, 'a lance is 6 over, so his Spear 5 rolls as 0', 'a lance is 6 over, so his Lance 5 rolls as 0') WHERE key = 'items';
END $do$;

