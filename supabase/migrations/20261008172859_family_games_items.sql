CREATE OR REPLACE FUNCTION public.family_game_record(
  p_kid_id uuid, p_game text, p_score integer, p_detail jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_best integer;
  v_levels jsonb;
  v_unlocked jsonb;
  v_items jsonb;
BEGIN
  -- Parents (admins) and the family login only.
  IF NOT (COALESCE((SELECT auth_is_family()), false) OR COALESCE((SELECT family_is_parent()), false)) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  -- bookworm = Spelling Quest Fire, bookworm_battle = Spelling Quest Monsters, mathblast = Math Blast.
  IF p_game NOT IN ('bookworm', 'bookworm_battle', 'mathblast') THEN
    RAISE EXCEPTION 'Unknown game %', p_game;
  END IF;
  IF p_score IS NULL OR p_score < 0 THEN
    RAISE EXCEPTION 'Bad score';
  END IF;

  SELECT COALESCE(game_bests -> p_game, '{}'::jsonb) INTO v_old
  FROM family_kids
  WHERE id = p_kid_id AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kid not found';
  END IF;

  v_best := COALESCE((v_old ->> 'best')::integer, -1);

  -- levels: where each kind of problem left off (Math Blast); the latest value wins.
  v_levels := COALESCE(v_old -> 'levels', '{}'::jsonb);
  IF p_detail ? 'op' AND p_detail ? 'level' THEN
    v_levels := v_levels || jsonb_build_object(p_detail ->> 'op', (p_detail ->> 'level')::integer);
  END IF;

  -- unlocked: highest map level open per difficulty (Spelling Quest); it only ever goes up.
  v_unlocked := COALESCE(v_old -> 'unlocked', '{}'::jsonb);
  IF p_detail ? 'unlock_key' AND p_detail ? 'unlock' THEN
    v_unlocked := v_unlocked || jsonb_build_object(
      p_detail ->> 'unlock_key',
      GREATEST(COALESCE((v_unlocked ->> (p_detail ->> 'unlock_key'))::integer, 1), (p_detail ->> 'unlock')::integer)
    );
  END IF;

  -- items: potions carried between games (Spelling Quest Monsters); the game sends the full set, 0 to 5 of each.
  v_items := COALESCE(v_old -> 'items', '{}'::jsonb);
  IF jsonb_typeof(p_detail -> 'items') = 'object' THEN
    SELECT COALESCE(jsonb_object_agg(k, LEAST(5, GREATEST(0, COALESCE((p_detail -> 'items' ->> k)::integer, 0)))), '{}'::jsonb)
      INTO v_items
    FROM unnest(ARRAY['heal', 'power', 'freeze']) AS k;
  END IF;

  v_new := jsonb_build_object(
    'best',        GREATEST(v_best, p_score),
    'best_at',     CASE WHEN p_score > v_best THEN to_jsonb(now()) ELSE v_old -> 'best_at' END,
    'best_detail', CASE WHEN p_score > v_best THEN COALESCE(p_detail, '{}'::jsonb) - 'items' ELSE v_old -> 'best_detail' END,
    'plays',       COALESCE((v_old ->> 'plays')::integer, 0) + 1,
    'last',        p_score,
    'last_at',     to_jsonb(now()),
    'levels',      v_levels,
    'unlocked',    v_unlocked,
    'items',       v_items
  );

  UPDATE family_kids
  SET game_bests = jsonb_set(COALESCE(game_bests, '{}'::jsonb), ARRAY[p_game], v_new, true)
  WHERE id = p_kid_id;

  RETURN v_new;
END $$;

