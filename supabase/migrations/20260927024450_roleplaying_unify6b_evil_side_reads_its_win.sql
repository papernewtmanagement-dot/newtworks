-- Roleplaying unify6b: on a sheet, a Spirit pair's evil side reads how far it wins (0 when it loses) instead of always
-- 0. The good side still carries the pair's net for every formula (no formula reads an evil side). Found by the
-- sanctify roll: the Bramblemaw's Fascination with Evil read 0; it is 12 (Fascination 12 over Connection 0).
-- A good character is unchanged (its evil sides lose, so they still read 0).
DO $$
DECLARE
  v text := pg_get_functiondef('public.rpg_sheet_values(uuid)'::regprocedure);
  a text := 'v_vals := v_vals || jsonb_build_object(v_d.key, abs(v_good - v_evil), v_d.pair_key, 0);';
  b text := 'v_vals := v_vals || jsonb_build_object(v_d.key, abs(v_good - v_evil), v_d.pair_key, greatest(v_evil - v_good, 0));';
  c text := '-- paired Spirit traits: the net (winner minus loser) feeds every formula; the label is the winner''s.';
  d text := '-- paired Spirit traits: the net (winner minus loser) sits on the good side and feeds every formula; the label is the
  -- winner''s. The evil side reads how far it wins, 0 when it loses (the Bramblemaw''s Fascination with Evil 12).';
BEGIN
  IF (length(v) - length(replace(v, a, ''))) / length(a) <> 1 OR (length(v) - length(replace(v, c, ''))) / length(c) <> 1 THEN
    RAISE EXCEPTION 'rpg_sheet_values anchors not found exactly once';
  END IF;
  EXECUTE replace(replace(v, a, b), c, d);
END $$;
