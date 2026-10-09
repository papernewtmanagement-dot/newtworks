-- Family games (Bookworm, Math Blast): each kid's best scores live on their own row.
ALTER TABLE public.family_kids ADD COLUMN IF NOT EXISTS game_bests jsonb NOT NULL DEFAULT '{}'::jsonb;

-- Saves one finished game for one kid. The family login can only read family_kids,
-- so this runs as the owner after checking the caller is a parent or the family login.
-- game_bests.<game> = {best, best_at, best_detail, plays, last, last_at, levels}
-- levels (Math Blast only) = where each kind of problem left off, so the next game starts there.
CREATE OR REPLACE FUNCTION public.family_game_record(
  p_kid_id uuid, p_game text, p_score integer, p_detail jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_old jsonb;
  v_new jsonb;
  v_best integer;
  v_levels jsonb;
BEGIN
  IF NOT COALESCE((SELECT auth_is_family()), false) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  IF p_game NOT IN ('bookworm', 'mathblast') THEN
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
  v_levels := COALESCE(v_old -> 'levels', '{}'::jsonb);
  IF p_detail ? 'op' AND p_detail ? 'level' THEN
    v_levels := v_levels || jsonb_build_object(p_detail ->> 'op', (p_detail ->> 'level')::integer);
  END IF;

  v_new := jsonb_build_object(
    'best',        GREATEST(v_best, p_score),
    'best_at',     CASE WHEN p_score > v_best THEN to_jsonb(now()) ELSE v_old -> 'best_at' END,
    'best_detail', CASE WHEN p_score > v_best THEN COALESCE(p_detail, '{}'::jsonb) ELSE v_old -> 'best_detail' END,
    'plays',       COALESCE((v_old ->> 'plays')::integer, 0) + 1,
    'last',        p_score,
    'last_at',     to_jsonb(now()),
    'levels',      v_levels
  );

  UPDATE family_kids
  SET game_bests = jsonb_set(COALESCE(game_bests, '{}'::jsonb), ARRAY[p_game], v_new, true)
  WHERE id = p_kid_id;

  RETURN v_new;
END $$;

REVOKE ALL ON FUNCTION public.family_game_record(uuid, text, integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_game_record(uuid, text, integer, jsonb) TO authenticated;

