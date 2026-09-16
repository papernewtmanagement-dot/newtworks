-- The screen needs to know whether the person looking at it is the host, the
-- same way the Shared Grid state does, so the controls can be hidden rather
-- than failing on click.
CREATE OR REPLACE FUNCTION public._quiz_hangman_state_row(p_sess public.quiz_hangman_sessions)
RETURNS jsonb LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $fn$
DECLARE v_item public.quiz_items; v_mask text;
BEGIN
  SELECT * INTO v_item FROM public.quiz_items WHERE id = p_sess.item_id;
  v_mask := public._quiz_hangman_mask(p_sess.phrase, p_sess.guessed_letters);
  RETURN jsonb_build_object(
    'id', p_sess.id,
    'status', p_sess.status,
    'is_host', (p_sess.host_team_member_id = public.current_team_member_id()),
    'players', p_sess.players,
    'current_player_index', p_sess.current_player_index,
    'masked', v_mask,
    'guessed_letters', to_jsonb(p_sess.guessed_letters),
    'misses', p_sess.misses,
    'max_misses', p_sess.max_misses,
    'round', p_sess.round,
    'round_over', p_sess.round_over,
    'solved', p_sess.solved,
    'category', v_item.category,
    'letters_left', (length(v_mask) - length(replace(v_mask, '_', ''))),
    'phrase', CASE WHEN p_sess.round_over OR p_sess.status = 'finished' THEN upper(p_sess.phrase) ELSE NULL END,
    'stem', CASE WHEN p_sess.round_over OR p_sess.status = 'finished' THEN v_item.stem ELSE NULL END,
    'explanation', CASE WHEN p_sess.round_over OR p_sess.status = 'finished' THEN v_item.explanation ELSE NULL END
  );
END; $fn$;

REVOKE ALL ON FUNCTION public._quiz_hangman_state_row(public.quiz_hangman_sessions) FROM PUBLIC;
