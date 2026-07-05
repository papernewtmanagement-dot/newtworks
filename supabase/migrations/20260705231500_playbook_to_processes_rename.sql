-- Rename public.playbook → public.processes + all dependent objects.
-- Companion frontend commit updates .from("playbook"), URL paths, nav id, task_category values.
-- Compat view public.playbook remains until edge functions are redeployed.

-- 1. Rename table
ALTER TABLE public.playbook RENAME TO processes;

-- 2. Rename indexes
ALTER INDEX public.playbook_pkey RENAME TO processes_pkey;
ALTER INDEX public.playbook_agency_active_idx RENAME TO processes_agency_active_idx;
ALTER INDEX public.playbook_confluence_page_id_idx RENAME TO processes_confluence_page_id_idx;
ALTER INDEX public.playbook_one_active_per_title RENAME TO processes_one_active_per_title;
ALTER INDEX public.playbook_tree_root_idx RENAME TO processes_tree_root_idx;

-- 3. Rename RLS policies
ALTER POLICY anon_all_playbook ON public.processes RENAME TO anon_all_processes;
ALTER POLICY authenticated_all_playbook ON public.processes RENAME TO authenticated_all_processes;

-- 4. Recreate refresh_daily_checklist_huddle_summary pointing at public.processes
CREATE OR REPLACE FUNCTION public.refresh_daily_checklist_huddle_summary(p_agency_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_summary TEXT;
  v_current TEXT;
  v_new TEXT;
BEGIN
  v_summary := public.render_huddle_summary_md(p_agency_id);

  SELECT content INTO v_current
  FROM public.processes
  WHERE agency_id = p_agency_id AND title = '04 Daily Checklist';
  IF NOT FOUND THEN RETURN; END IF;

  IF v_current NOT LIKE '%<!-- HUDDLE_SUMMARY:START -->%' THEN
    RETURN;
  END IF;

  v_new := regexp_replace(
    v_current,
    '<!-- HUDDLE_SUMMARY:START -->[\s\S]*?<!-- HUDDLE_SUMMARY:END -->',
    '<!-- HUDDLE_SUMMARY:START -->' || E'\n' || v_summary || E'\n' || '<!-- HUDDLE_SUMMARY:END -->',
    'g'
  );

  IF v_new IS DISTINCT FROM v_current THEN
    UPDATE public.processes
    SET content = v_new, updated_at = NOW()
    WHERE agency_id = p_agency_id AND title = '04 Daily Checklist';
  END IF;
END;
$function$;

-- 5. tasks.task_category: rename value 'playbook' → 'processes' + update CHECK
ALTER TABLE public.tasks DROP CONSTRAINT tasks_task_category_check;
UPDATE public.tasks SET task_category = 'processes' WHERE task_category = 'playbook';
ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_task_category_check
  CHECK (
    task_category IS NULL
    OR task_category = ANY (ARRAY['web_app'::text,'admin'::text,'marketing'::text,'team_development'::text,'handbook'::text,'processes'::text,'finances'::text])
  );

-- 6. Backward-compat view for callers still holding onto "playbook" (edge functions,
--    OLD Vercel build during switchover). security_invoker=true keeps RLS scoped
--    to the caller, not the view owner.
CREATE VIEW public.playbook
WITH (security_invoker = true) AS
SELECT * FROM public.processes;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.playbook TO anon, authenticated;

COMMENT ON VIEW public.playbook IS
  'Backward-compat pass-through for the renamed public.processes table. Safe to DROP once every caller (frontend, edge functions) has been migrated to public.processes.';
