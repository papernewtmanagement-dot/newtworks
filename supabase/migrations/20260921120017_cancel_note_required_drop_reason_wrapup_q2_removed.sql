-- Peter 2026-09-21: the separate cancelation reason is gone; the note carries the reason and is
-- required on every cancelation the team logs. Wrap-up question 2 (lapse/cancel trends) is deleted.
DO $mig$
DECLARE
  f text; g text;
  PROCEDURE_NAMES text[] := ARRAY[]::text[];
BEGIN
  -- 1. rp_log_cancelation: a note is required unless it is backfilled history
  f := pg_get_functiondef('public.rp_log_cancelation(jsonb)'::regprocedure);
  g := replace(f,
    $a$  v_note   := NULLIF(btrim(COALESCE(p->>'note','')), '');$a$,
    $a$  v_note   := NULLIF(btrim(COALESCE(p->>'note','')), '');
  IF v_note IS NULL AND NOT v_backfill THEN
    RAISE EXCEPTION 'a cancelation needs a note on why it canceled';
  END IF;$a$);
  IF g = f THEN RAISE EXCEPTION 'rp_log_cancelation anchor not found'; END IF;
  EXECUTE g;

  -- 2. rp_edit_cancelation: the note cannot be cleared on a later edit
  f := pg_get_functiondef('public.rp_edit_cancelation(uuid,jsonb)'::regprocedure);
  g := replace(f,
    $a$  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);$a$,
    $a$  IF c ? 'note' AND NULLIF(btrim(COALESCE(c->>'note','')), '') IS NULL AND r.entry_source = 'manual' THEN
    RAISE EXCEPTION 'a cancelation needs a note on why it canceled, so it cannot be cleared';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);$a$);
  IF g = f THEN RAISE EXCEPTION 'rp_edit_cancelation anchor not found'; END IF;
  EXECUTE g;

  -- 3. rp_convert_activity_to_cancelation: no made-up "other" reason; an entry saved before notes
  --    were required still converts, with a note saying where it came from
  f := pg_get_functiondef('public.rp_convert_activity_to_cancelation(uuid,jsonb,text,uuid[])'::regprocedure);
  g := replace(f,
    $a$      'reason', COALESCE(NULLIF(btrim(COALESCE(item->>'reason','')), ''), 'other'),
      'note', l.note,$a$,
    $a$      'note', COALESCE(NULLIF(btrim(COALESCE(l.note, '')), ''), 'Turned into a cancelation at spot-check'),$a$);
  IF g = f THEN RAISE EXCEPTION 'rp_convert_activity_to_cancelation anchor not found'; END IF;
  EXECUTE g;

  -- 4. rp_log_entry: carry the replacement flag through to the cancelation record
  f := pg_get_functiondef('public.rp_log_entry(jsonb)'::regprocedure);
  g := replace(f,
    $a$'reason', v_cxl->>'reason', 'note', v_note, 'team_member_id', v_tm));$a$,
    $a$'replacement', COALESCE((it->>'replacement')::boolean, false),
        'note', v_note, 'team_member_id', v_tm));$a$);
  IF g = f THEN RAISE EXCEPTION 'rp_log_entry anchor not found'; END IF;
  EXECUTE g;

  -- 5. my_wrapup_save: as many answers as there are questions, not a fixed six
  f := pg_get_functiondef('public.my_wrapup_save(jsonb,text,text,date)'::regprocedure);
  g := replace(f, $a$  FOR i IN 1..6 LOOP$a$, $a$  FOR i IN 1..jsonb_array_length(v_prompts) LOOP$a$);
  IF g = f THEN RAISE EXCEPTION 'my_wrapup_save anchor not found'; END IF;
  EXECUTE g;
END
$mig$;

CREATE OR REPLACE FUNCTION public.my_wrapup_prompts()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT jsonb_build_array(
    jsonb_build_object('n', 1, 'title', 'Personal life & annuity status updates',           'hint', 'Your book, pending apps, upcoming reviews.'),
    jsonb_build_object('n', 2, 'title', 'Personal obstacles + solutions',                   'hint', 'What is in your way, and what you propose.'),
    jsonb_build_object('n', 3, 'title', 'Plan for a 1% increase in sales points next week', 'hint', 'What you will do differently.'),
    jsonb_build_object('n', 4, 'title', 'Efficiency / pain-point recommendation',           'hint', 'One thing that would make the office run better.'),
    jsonb_build_object('n', 5, 'title', 'Brags on teammates',                               'hint', 'Something you saw that matched our mission or their job description.')
  );
$function$;
