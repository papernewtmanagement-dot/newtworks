-- A task created for a step that is already checked off now starts completed,
-- dated when the step was done. Before this, onboarding_sync_plan always
-- inserted 'open', so a re-sync left finished steps (background check,
-- reference check) as open work on Peter's list. Found 2026-09-25 on the
-- Oct 5 plans. Patched in place so every caller moves together; each edit
-- must match exactly once or the migration stops.
DO $mig$
DECLARE
  v_old  text := pg_get_functiondef('public.onboarding_sync_plan(uuid)'::regprocedure);
  v_new  text;
  v_from text[] := ARRAY[
    's.task_id, s.unlocks_on, ph.name AS phase_name',
    'status, due_date, related_id, created_by',
    '''open'', v_due, r.id, ''onboarding_plan'''
  ];
  v_to   text[] := ARRAY[
    's.task_id, s.unlocks_on, s.completed_at, ph.name AS phase_name',
    'status, due_date, related_id, created_by, completed_at',
    'CASE WHEN r.completed_at IS NOT NULL THEN ''completed'' ELSE ''open'' END, v_due, r.id, ''onboarding_plan'', r.completed_at'
  ];
  v_hits int;
  i      int;
BEGIN
  v_new := v_old;
  FOR i IN 1 .. array_length(v_from, 1) LOOP
    v_hits := (length(v_new) - length(replace(v_new, v_from[i], ''))) / length(v_from[i]);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'onboarding_sync_plan patch %: expected 1 match, found %', i, v_hits;
    END IF;
    v_new := replace(v_new, v_from[i], v_to[i]);
  END LOOP;
  EXECUTE v_new;
END
$mig$;
