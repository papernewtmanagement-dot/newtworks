-- Fix to unify3b: an experience entry with no divider showed its roll's top as 100 (greatest() skips a missing divider,
-- so it fell to 1). The top of a roll with no divider is the standard one, 10.
DO $$
DECLARE v_def text := pg_get_functiondef('public.rpg_creature_card(uuid)'::regprocedure);
        v_old text := $o$coalesce(ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)), ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')))$o$;
        v_new text := $n$CASE WHEN b.value ? 'divisor' THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) ELSE ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')) END$n$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 2 THEN
    RAISE EXCEPTION 'rpg_creature_card: expected the start_top expression exactly twice';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;

