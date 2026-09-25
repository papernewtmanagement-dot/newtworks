-- A target at 0 vitality is down, and someone who is down cannot act: they are hit at their skill × 1, not × 2.
-- Bite's card note and the Taking Turns rule card both say so. Karen down with Evade Enemy 5: difficulty 5, not 10,
-- so Bramblemaw's Bite (skill 10) needs 34 instead of 50. Edits the one line in rpg_act that derives the difficulty;
-- nothing else in the function changes.
DO $$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public.rpg_act(uuid, uuid[], text, uuid, text, numeric)'::regprocedure);
  IF position('v_diff := public.rpg_difficulty(v_def, v_t.can_act);' IN v_def) = 0
     OR position('-- target''s stat × 2 when they can act, × 1 when they cannot. With no target' IN v_def) = 0 THEN
    RAISE EXCEPTION 'rpg_act is not the version this edit expects';
  END IF;
  v_def := replace(v_def, 'v_diff := public.rpg_difficulty(v_def, v_t.can_act);',
                   'v_diff := public.rpg_difficulty(v_def, v_t.can_act AND (public.rpg_participant_vitality(v_tid)->>''left'')::integer > 0);');
  v_def := replace(v_def, '-- target''s stat × 2 when they can act, × 1 when they cannot. With no target',
                   '-- target''s stat × 2 when they can act, × 1 when they cannot (held, asleep, or down at 0 vitality). With no target');
  EXECUTE v_def;
END $$;
