-- Peter approved removing both leftovers (2026-09-15).
-- The weekly scoreboard was the last reader of the sales sourced-by field, in
-- four places. Each one fell back to the owner anyway, so it now just uses the
-- owner. The quote log keeps its own sourced-by field, untouched.
DO $do$
DECLARE v_def text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';
  IF v_def IS NULL THEN RAISE EXCEPTION 'rp_week_scoreboard_for not found'; END IF;

  v_new := replace(v_def, 'COALESCE(s.sourced_by_team_member_id, s.team_member_id)', 's.team_member_id');
  v_new := replace(v_new, 'COALESCE(p.sourced_by_team_member_id, p.team_member_id)', 'p.team_member_id');

  IF v_new LIKE '%s.sourced_by_team_member_id%' OR v_new LIKE '%p.sourced_by_team_member_id%' THEN
    RAISE EXCEPTION 'a sales sourced-by reference is still in there. Nothing changed.';
  END IF;
  IF v_new = v_def THEN
    RAISE EXCEPTION 'nothing matched. Nothing changed.';
  END IF;
  EXECUTE v_new;
END $do$;

-- Nothing anywhere should still read either one.
DO $do$
DECLARE v_names text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ') INTO v_names
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND (p.prosrc LIKE '%book_alpha_split%'
       OR p.prosrc LIKE '%s.sourced_by_team_member_id%'
       OR p.prosrc LIKE '%p.sourced_by_team_member_id%');
  IF v_names IS NOT NULL THEN
    RAISE EXCEPTION 'still referenced by: %. Not dropping anything.', v_names;
  END IF;
END $do$;

ALTER TABLE public.sales_log DROP COLUMN IF EXISTS sourced_by_team_member_id;

DROP TABLE IF EXISTS public.book_alpha_split;
