-- Spelling Quest Family mode: family_game_record accepts game 'bookworm_family'.
CREATE OR REPLACE FUNCTION public.family_game_record(p_kid_id uuid, p_game text, p_score integer, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_best integer;
  v_levels jsonb;
  v_unlocked jsonb;
  v_items jsonb;
  v_stars jsonb;
  v_equip jsonb;
  v_txp jsonb;
  v_i integer;
  v_books jsonb;
  v_k text;
  v_arr jsonb;
BEGIN
  -- Parents (admins) and the family login only.
  IF NOT (COALESCE((SELECT auth_is_family()), false) OR COALESCE((SELECT family_is_parent()), false)) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  -- bookworm = Spelling Quest Fire, bookworm_battle = Spelling Quest Monsters,
  -- bookworm_family = Spelling Quest Family (one word a turn; best = top word score, best_detail.word = that word), mathblast = Math Blast.
  IF p_game NOT IN ('bookworm', 'bookworm_battle', 'bookworm_family', 'mathblast') THEN
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
    FROM unnest(ARRAY['heal', 'power', 'freeze', 'cure']) AS k;
  END IF;

  -- stars: best stars (1-3) per "difficulty:level" (Spelling Quest Monsters); only ever goes up.
  v_stars := COALESCE(v_old -> 'stars', '{}'::jsonb);
  IF p_detail ? 'stars_key' AND p_detail ? 'stars' THEN
    v_stars := v_stars || jsonb_build_object(
      left(p_detail ->> 'stars_key', 20),
      GREATEST(COALESCE((v_stars ->> left(p_detail ->> 'stars_key', 20))::integer, 0), LEAST(3, GREATEST(0, (p_detail ->> 'stars')::integer)))
    );
  END IF;

  -- equip: treasures worn (up to three numbers 0-19); the latest set wins.
  v_equip := COALESCE(v_old -> 'equip', '[]'::jsonb);
  IF jsonb_typeof(p_detail -> 'equip') = 'array' THEN
    SELECT COALESCE(jsonb_agg(DISTINCT v::integer), '[]'::jsonb) INTO v_equip
    FROM (SELECT v FROM jsonb_array_elements_text(p_detail -> 'equip') WITH ORDINALITY AS e(v, o)
          WHERE v ~ '^[0-9]{1,2}$' AND v::integer BETWEEN 0 AND 19 ORDER BY o LIMIT 3) s;
  END IF;

  -- treasure_xp: levels won while wearing each treasure (Spelling Quest Monsters); each listed treasure (0-19) gets one more win.
  v_txp := COALESCE(v_old -> 'treasure_xp', '{}'::jsonb);
  IF jsonb_typeof(p_detail -> 'treasure_xp_add') = 'array' THEN
    FOR v_i IN
      SELECT DISTINCT v::integer FROM jsonb_array_elements_text(p_detail -> 'treasure_xp_add') AS e(v)
      WHERE v ~ '^[0-9]{1,2}$' AND v::integer BETWEEN 0 AND 19
    LOOP
      v_txp := v_txp || jsonb_build_object(v_i::text, LEAST(999, COALESCE((v_txp ->> v_i::text)::integer, 0) + 1));
    END LOOP;
  END IF;

  -- books: words found in each word book (Spelling Quest Fire); found words only ever add up, 40 per book at most.
  v_books := COALESCE(v_old -> 'books', '{}'::jsonb);
  IF jsonb_typeof(p_detail -> 'books_add') = 'object' THEN
    FOR v_k IN
      SELECT k FROM jsonb_object_keys(p_detail -> 'books_add') AS k
      WHERE k ~ '^[a-z]{2,12}$' AND jsonb_typeof(p_detail -> 'books_add' -> k) = 'array'
      LIMIT 20
    LOOP
      SELECT COALESCE(jsonb_agg(w ORDER BY w), '[]'::jsonb) INTO v_arr
      FROM (
        SELECT DISTINCT w FROM (
          SELECT jsonb_array_elements_text(COALESCE(v_books -> v_k, '[]'::jsonb)) AS w
          UNION
          SELECT e.w FROM jsonb_array_elements_text(p_detail -> 'books_add' -> v_k) AS e(w) WHERE e.w ~ '^[a-z]{2,12}$'
        ) u ORDER BY w LIMIT 40
      ) x;
      v_books := v_books || jsonb_build_object(v_k, v_arr);
    END LOOP;
  END IF;

  -- bonus: a Spelling Quest bonus round only hands out potions; it is not a game played (plays, last and best stay as they are).
  IF COALESCE((p_detail ->> 'bonus')::boolean, false) THEN
    v_new := v_old || jsonb_build_object('items', v_items);
    UPDATE family_kids
    SET game_bests = jsonb_set(COALESCE(game_bests, '{}'::jsonb), ARRAY[p_game], v_new, true)
    WHERE id = p_kid_id;
    RETURN v_new;
  END IF;

  v_new := jsonb_build_object(
    'best',        GREATEST(v_best, p_score),
    'best_at',     CASE WHEN p_score > v_best THEN to_jsonb(now()) ELSE v_old -> 'best_at' END,
    'best_detail', CASE WHEN p_score > v_best THEN COALESCE(p_detail, '{}'::jsonb) - 'items' - 'equip' - 'treasure_xp_add' - 'books_add' ELSE v_old -> 'best_detail' END,
    'plays',       COALESCE((v_old ->> 'plays')::integer, 0) + 1,
    'last',        p_score,
    'last_at',     to_jsonb(now()),
    'levels',      v_levels,
    'unlocked',    v_unlocked,
    'items',       v_items,
    'stars',       v_stars,
    'equip',       v_equip,
    'treasure_xp', v_txp,
    'books',       v_books
  );

  UPDATE family_kids
  SET game_bests = jsonb_set(COALESCE(game_bests, '{}'::jsonb), ARRAY[p_game], v_new, true)
  WHERE id = p_kid_id;

  RETURN v_new;
END $function$;
