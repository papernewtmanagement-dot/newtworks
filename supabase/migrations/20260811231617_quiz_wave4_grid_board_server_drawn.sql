CREATE UNIQUE INDEX IF NOT EXISTS uq_quiz_attempts_the_grid
  ON public.quiz_attempts (agency_id, team_member_id, attempt_day)
  WHERE mode_key = 'the_grid';

CREATE OR REPLACE FUNCTION public.quiz_start_grid_attempt()
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_agency uuid; v_member uuid; v_existing uuid; v_fin timestamptz;
  v_cats text[]; v_cat text; v_items jsonb;
  v_board jsonb := '[]'::jsonb; v_points jsonb := '[]'::jsonb;
  v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  -- One board per person per Central-time day. Unfinished one resumes
  -- with its pinned board; a finished one refuses.
  SELECT id, finished_at INTO v_existing, v_fin
    FROM public.quiz_attempts
   WHERE agency_id = v_agency AND team_member_id = v_member
     AND mode_key = 'the_grid'
     AND attempt_day = ((now() AT TIME ZONE 'America/Chicago')::date);
  IF v_existing IS NOT NULL THEN
    IF v_fin IS NOT NULL THEN
      RAISE EXCEPTION 'the board is once a day - come back tomorrow';
    END IF;
    RETURN v_existing;
  END IF;

  SELECT array_agg(c.category ORDER BY c.n DESC, c.category)
    INTO v_cats
    FROM (SELECT qi.category, COUNT(*) AS n
            FROM public.quiz_items qi
           WHERE qi.agency_id = v_agency AND qi.status = 'approved'
             AND qi.report_blocked = false AND qi.category IS NOT NULL
           GROUP BY qi.category
          HAVING COUNT(*) >= 5
           ORDER BY COUNT(*) DESC, qi.category
           LIMIT 5) c;

  IF v_cats IS NULL OR array_length(v_cats, 1) < 3 THEN
    RAISE EXCEPTION 'the board needs at least three categories with five approved questions each (have %)',
      COALESCE(array_length(v_cats, 1), 0);
  END IF;

  FOREACH v_cat IN ARRAY v_cats LOOP
    SELECT jsonb_agg(jsonb_build_object('item_id', y.id, 'points', y.rn * 10)
                     ORDER BY y.rn)
      INTO v_items
      FROM (
        SELECT p.id,
               row_number() OVER (ORDER BY CASE p.difficulty
                                             WHEN 'basic' THEN 1
                                             WHEN 'intermediate' THEN 2
                                             ELSE 3 END, p.id) AS rn
          FROM (SELECT qi.id, qi.difficulty
                  FROM public.quiz_items qi
                 WHERE qi.agency_id = v_agency AND qi.status = 'approved'
                   AND qi.report_blocked = false AND qi.category = v_cat
                 ORDER BY random() LIMIT 5) p
      ) y;

    v_board  := v_board || jsonb_build_array(
                  jsonb_build_object('category', v_cat, 'clues', v_items));
    v_points := v_points || v_items;
  END LOOP;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, context)
  VALUES (v_agency, v_member, 'the_grid',
          jsonb_build_object(
            'board', v_board,
            'board_points', v_points,
            'item_ids', (SELECT jsonb_agg(e->'item_id')
                           FROM jsonb_array_elements(v_points) e)))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $$;

REVOKE ALL ON FUNCTION public.quiz_start_grid_attempt() FROM anon, public;
GRANT EXECUTE ON FUNCTION public.quiz_start_grid_attempt() TO authenticated;

UPDATE public.quiz_modes SET wager_allowed = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND mode_key = 'the_grid';
