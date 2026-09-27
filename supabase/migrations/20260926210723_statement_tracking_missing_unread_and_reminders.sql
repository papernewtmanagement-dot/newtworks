-- Statement tracking: which statements are missing or unread, per account,
-- shown on the Accounts page and sent to Alvi as a reminder the day after a
-- statement is due. Peter 2026-09-26.
--
-- ONE definition of "missing": public.statement_issues(agency). The Accounts
-- page (v_statement_issues), the red "overdue" flag in v_bank_balances /
-- v_card_balances, and the reminder all read it, so they can never disagree.

-- 1. Account settings the definition needs -----------------------------------
ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS statement_ready_days smallint NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS statement_covered_by_account_id uuid REFERENCES public.accounts(id);

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'accounts_statement_ready_days_check') THEN
    ALTER TABLE public.accounts ADD CONSTRAINT accounts_statement_ready_days_check
      CHECK (statement_ready_days BETWEEN 0 AND 30);
  END IF;
END $$;

COMMENT ON COLUMN public.accounts.statement_ready_days IS
  'Days after the statement closes that it is normally available to download. A statement is DUE on close date + this many days; the reminder goes out the day after. Banks and cards post in 1-3 days (default 3); Fidelity posts the monthly report about 10 days after month end.';
COMMENT ON COLUMN public.accounts.statement_covered_by_account_id IS
  'Set when this account has no statement of its own and is printed on another account''s statement (RBFCU checking is on the RBFCU savings statement). Such an account is never reported missing.';

-- Chase Marketing (7762) closes on the 22nd, the agency card (3447) on the 16th-18th.
-- Without a close day these two could never be flagged, which is how the agency
-- card''s Jul 17 - Aug 18 statement went unnoticed.
UPDATE public.accounts SET statement_close_day = 22
 WHERE id = '37c0a92a-66b8-42d4-a602-cd36734f375f' AND statement_close_day IS NULL;
UPDATE public.accounts SET statement_close_day = 17
 WHERE id = '42b19c52-b02c-4b71-9976-c98a67323270' AND statement_close_day IS NULL;
-- RBFCU checking is printed on the RBFCU savings statement (combined statement).
UPDATE public.accounts SET statement_covered_by_account_id = 'b6d516fc-6038-4528-beac-0c7cd1df8543'
 WHERE id = 'a388d044-5c60-41cf-9174-e7e58173bc22';
-- Fidelity's monthly report posts about 10 days after month end.
UPDATE public.accounts SET statement_ready_days = 10
 WHERE id = '8bdcbd72-7d92-405a-a251-b76842b5bbcd';

-- 2. When a statement is due --------------------------------------------------
CREATE OR REPLACE FUNCTION public.statement_due_date(p_close date, p_ready_days smallint)
RETURNS date LANGUAGE sql IMMUTABLE AS $$ SELECT p_close + COALESCE(p_ready_days, 3)::int $$;

-- 3. The one definition of missing / unread statements -------------------------
--   missing  a statement period with no statement on file and past its due date:
--            either a hole between two statements whose balances do not chain
--            (the closing balance of one is not the opening of the next), or a
--            statement that should have closed since the latest one on file.
--            A period is NOT missing when a file for it has arrived and is only
--            waiting to be read (that shows as waiting/unread instead).
--   unread   a statement file that arrived but could not be read.
--   waiting  a statement file that arrived and is queued to be read.
CREATE OR REPLACE FUNCTION public.statement_issues(p_agency_id uuid)
RETURNS TABLE (
  agency_id uuid, account_id uuid, account_code text, account_name text, institution text,
  last4 text, business_entity_id uuid, account_kind text, issue text,
  period_start date, period_end date, due_date date, document_id uuid, file_name text, detail text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
WITH acct AS (
  SELECT a.id AS account_id, a.agency_id, a.business_entity_id, a.account_name, a.institution,
         a.account_number_last4 AS last4, a.account_kind, a.statement_close_day AS close_day,
         a.statement_ready_days AS ready_days, coa.account_code
    FROM accounts a
    JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
   WHERE a.agency_id = p_agency_id AND a.is_active AND a.statement_covered_by_account_id IS NULL
     -- Signed-in callers see only their own agency, and never a family login.
     -- Scheduled jobs run with no signed-in user and see the agency they name.
     AND (auth.uid() IS NULL OR EXISTS (SELECT 1 FROM users u
                                         WHERE u.auth_user_id = auth.uid() AND u.agency_id = p_agency_id
                                           AND u.role <> 'family'))
),
sb AS (
  SELECT s.account_code, s.statement_period_start AS ps, s.statement_period_end AS pe,
         s.opening_balance AS ob, s.closing_balance AS cb,
         lag(s.statement_period_end) OVER w AS prev_pe,
         lag(s.closing_balance) OVER w AS prev_cb
    FROM statement_balances s
   WHERE s.agency_id = p_agency_id
  WINDOW w AS (PARTITION BY s.account_code ORDER BY s.statement_period_end)
),
pending_docs AS (
  SELECT d.source_account_code AS account_code, d.id AS document_id, d.file_name,
         d.processing_status, d.created_at
    FROM documents d
   WHERE d.agency_id = p_agency_id
     AND d.source_account_code IS NOT NULL
     AND d.processing_status IN ('queued_for_llm', 'error', 'held_reconciliation_mismatch')
     AND d.created_at > now() - interval '120 days'
     AND NOT EXISTS (SELECT 1 FROM statement_balances s2 WHERE s2.source_document_id = d.id)
),
gaps AS (
  SELECT a.*, (sb.prev_pe + 1) AS p_start, (sb.ps - 1) AS p_end
    FROM acct a JOIN sb ON sb.account_code = a.account_code
   WHERE sb.prev_pe IS NOT NULL AND sb.ps IS NOT NULL AND sb.ps - sb.prev_pe > 5
     AND round(sb.prev_cb, 2) IS DISTINCT FROM round(sb.ob, 2)
),
latest AS (
  SELECT DISTINCT ON (account_code) account_code, pe AS last_pe
    FROM sb ORDER BY account_code, pe DESC
),
expected AS (
  SELECT a.*, e.close_date,
         COALESCE(lag(e.close_date) OVER (PARTITION BY a.account_id ORDER BY e.close_date), l.last_pe) + 1 AS p_start
    FROM acct a
    JOIN latest l ON l.account_code = a.account_code
    CROSS JOIN LATERAL (
      SELECT (m + (LEAST(a.close_day, extract(day FROM (m + interval '1 month' - interval '1 day'))::int) - 1)
                  * interval '1 day')::date AS close_date
        FROM generate_series(date_trunc('month', l.last_pe) + interval '1 month',
                             date_trunc('month', current_date), interval '1 month') AS m
    ) e
   WHERE a.close_day IS NOT NULL
)
SELECT g.agency_id, g.account_id, g.account_code, g.account_name, g.institution, g.last4,
       g.business_entity_id, g.account_kind, 'missing'::text,
       g.p_start, g.p_end, statement_due_date(g.p_end, g.ready_days), NULL::uuid, NULL::text,
       format('Statement for %s – %s is missing', to_char(g.p_start, 'Mon FMDD'), to_char(g.p_end, 'Mon FMDD'))
  FROM gaps g
UNION ALL
SELECT x.agency_id, x.account_id, x.account_code, x.account_name, x.institution, x.last4,
       x.business_entity_id, x.account_kind, 'missing'::text,
       x.p_start, x.close_date, statement_due_date(x.close_date, x.ready_days), NULL::uuid, NULL::text,
       format('Statement for %s – %s hasn''t come in (due %s)', to_char(x.p_start, 'Mon FMDD'),
              to_char(x.close_date, 'Mon FMDD'), to_char(statement_due_date(x.close_date, x.ready_days), 'Mon FMDD'))
  FROM expected x
 WHERE statement_due_date(x.close_date, x.ready_days) < current_date
   AND NOT EXISTS (SELECT 1 FROM pending_docs p
                    WHERE p.account_code = x.account_code AND p.created_at::date >= x.close_date)
UNION ALL
SELECT a.agency_id, a.account_id, a.account_code, a.account_name, a.institution, a.last4,
       a.business_entity_id, a.account_kind,
       CASE WHEN p.processing_status = 'queued_for_llm' THEN 'waiting' ELSE 'unread' END,
       NULL::date, NULL::date, NULL::date, p.document_id, p.file_name,
       CASE WHEN p.processing_status = 'queued_for_llm'
            THEN format('%s is waiting to be read', p.file_name)
            ELSE format('%s couldn''t be read yet', p.file_name) END
  FROM pending_docs p JOIN acct a ON a.account_code = p.account_code
$$;

-- The balance views call this, and a view's user needs EXECUTE on functions it
-- calls, so signed-in users keep it; the guard above limits what they see.
REVOKE ALL ON FUNCTION public.statement_issues(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.statement_issues(uuid) TO authenticated;

-- What the Accounts page reads: the signed-in user's agency, never family logins.
CREATE OR REPLACE VIEW public.v_statement_issues AS
SELECT si.*
  FROM public.users u
  CROSS JOIN LATERAL public.statement_issues(u.agency_id) si
 WHERE u.auth_user_id = auth.uid() AND u.role <> 'family';

GRANT SELECT ON public.v_statement_issues TO authenticated;

-- 4. The red "overdue" flag on the balance views now reads the same definition.
--    Only the is_overdue expression changes; every other column is untouched.
DO $$
DECLARE
  v_name text;
  v_def text;
  v_old text := 'b.statement_close_day IS NOT NULL AND compute_next_statement_close(b.statement_close_day, b.last_statement_period_end) < CURRENT_DATE AS is_overdue';
  v_new text := '(EXISTS ( SELECT 1 FROM statement_issues(b.agency_id) si WHERE si.account_id = b.account_id AND si.issue = ''missing''::text)) AS is_overdue';
BEGIN
  FOREACH v_name IN ARRAY ARRAY['v_bank_balances', 'v_card_balances'] LOOP
    v_def := pg_get_viewdef(('public.' || v_name)::regclass, true);
    IF position(v_old IN v_def) = 0 THEN
      RAISE EXCEPTION '%: is_overdue expression not found as expected; view left unchanged', v_name;
    END IF;
    EXECUTE format('CREATE OR REPLACE VIEW public.%I AS %s', v_name, replace(v_def, v_old, v_new));
  END LOOP;
END $$;

-- 5. Reminders sent, so each statement is chased once and closes itself -------
CREATE TABLE IF NOT EXISTS public.statement_reminders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  account_id uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  period_start date,
  period_end date NOT NULL,
  due_date date,
  task_id uuid REFERENCES public.tasks(id) ON DELETE SET NULL,
  reminded_at timestamptz NOT NULL DEFAULT now(),
  telegram_result jsonb,
  resolved_at timestamptz,
  UNIQUE (account_id, period_end)
);
ALTER TABLE public.statement_reminders ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.statement_reminders IS
  'One row per missing statement Alvi was reminded about. Written only by statement_reminder_send(). resolved_at is stamped, and the task closed, once the statement is on file.';

-- 6. The reminder ---------------------------------------------------------------
-- Settings come from the recipe''s input_config: assignee_user_id (Alvi),
-- route (Telegram route key, admin = Paper Newt Management group).
-- p_window_days: statements that became due within this many days are sent;
-- older ones are left for a person to decide. The daily recipe uses 7 so a
-- missed run catches up, and nothing from before this was built goes out on its own.
CREATE OR REPLACE FUNCTION public.statement_reminder_send(
  p_agency_id uuid, p_recipe_id uuid, p_window_days int DEFAULT 7, p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_cfg jsonb;
  v_assignee uuid;
  v_route text;
  v_resolved int := 0;
  v_new int := 0;
  v_lines text := '';
  v_msg text;
  v_tg jsonb;
  r record;
  v_task uuid;
  v_reminder_ids uuid[] := '{}';
BEGIN
  SELECT input_config INTO v_cfg FROM automation_recipes WHERE id = p_recipe_id AND agency_id = p_agency_id;
  v_assignee := NULLIF(v_cfg->>'assignee_user_id', '')::uuid;
  v_route := COALESCE(NULLIF(v_cfg->>'route', ''), 'admin');
  IF v_assignee IS NULL THEN
    RAISE EXCEPTION 'statement reminder: recipe % has no assignee_user_id in input_config', p_recipe_id;
  END IF;

  -- a) Close out reminders whose statement is now on file.
  IF NOT p_dry_run THEN
    WITH gone AS (
      SELECT sr.id, sr.task_id
        FROM statement_reminders sr
       WHERE sr.agency_id = p_agency_id AND sr.resolved_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM statement_issues(p_agency_id) si
                          WHERE si.account_id = sr.account_id AND si.issue = 'missing'
                            AND si.period_end = sr.period_end)
    ), upd AS (
      UPDATE statement_reminders sr SET resolved_at = now() FROM gone WHERE sr.id = gone.id RETURNING gone.task_id
    )
    UPDATE tasks t SET status = 'completed', completed_at = now(), updated_at = now()
      FROM upd WHERE t.id = upd.task_id AND t.status NOT IN ('completed', 'closed');
    GET DIAGNOSTICS v_resolved = ROW_COUNT;
  END IF;

  -- b) New reminders: missing, due before today, due within the window, not yet sent.
  FOR r IN
    SELECT si.* FROM statement_issues(p_agency_id) si
     WHERE si.issue = 'missing'
       AND si.due_date < current_date
       AND si.due_date >= current_date - p_window_days
       AND NOT EXISTS (SELECT 1 FROM statement_reminders sr
                        WHERE sr.account_id = si.account_id AND sr.period_end = si.period_end)
     ORDER BY si.due_date, si.account_name
  LOOP
    v_new := v_new + 1;
    v_lines := v_lines || E'\n• ' || r.account_name
               || COALESCE(' ••' || r.last4, '') || ' (' || to_char(r.period_start, 'Mon FMDD') || ' – '
               || to_char(r.period_end, 'Mon FMDD') || ')';
    IF NOT p_dry_run THEN
      INSERT INTO tasks (agency_id, title, description, assigned_to, created_by, due_date, priority, status,
                         task_category, task_type, backlog_state, priority_source, estimated_hours_source, related_id)
      VALUES (p_agency_id,
              'Send the ' || r.account_name || COALESCE(' ••' || r.last4, '') || ' statement ('
                || to_char(r.period_start, 'Mon FMDD') || ' – ' || to_char(r.period_end, 'Mon FMDD') || ')',
              'Newtworks does not have this statement yet. It was due ' || to_char(r.due_date, 'Mon FMDD')
                || '. Download it from ' || COALESCE(r.institution, 'the bank')
                || ' and email it to paper.newt.management@gmail.com with "statement" in the subject. '
                || 'This task closes on its own once the statement has been read.',
              v_assignee, 'watcher:statement_reminder:' || r.account_code || ':' || r.period_end,
              current_date, 'medium', 'open', 'finances', 'task', 'active', 'auto', 'auto', r.account_id)
      RETURNING id INTO v_task;
      INSERT INTO statement_reminders (agency_id, account_id, period_start, period_end, due_date, task_id)
      VALUES (p_agency_id, r.account_id, r.period_start, r.period_end, r.due_date, v_task)
      RETURNING id INTO v_task;
      v_reminder_ids := v_reminder_ids || v_task;
    END IF;
  END LOOP;

  IF v_new > 0 THEN
    v_msg := 'Statements due and not in yet:' || v_lines || E'\n'
          || 'Alvi, please forward ' || CASE WHEN v_new = 1 THEN 'it' ELSE 'them' END
          || ' to paper.newt.management@gmail.com. '
          || CASE WHEN v_new = 1 THEN 'It''s' ELSE 'They''re' END
          || ' on your task list and drop off once read.';
    IF NOT p_dry_run THEN
      v_tg := telegram_send(v_route, v_msg, p_agency_id);
      UPDATE statement_reminders SET telegram_result = v_tg WHERE id = ANY (v_reminder_ids);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'records_processed', v_new,
    'output_summary', CASE WHEN p_dry_run THEN 'DRY RUN — nothing sent. ' ELSE '' END
      || v_new || ' statement reminder(s)' || CASE WHEN v_new > 0 THEN ' sent to ' || v_route ELSE '' END
      || '; ' || v_resolved || ' earlier reminder(s) closed because the statement arrived',
    'message', v_msg,
    'dry_run', p_dry_run
  );
END;
$$;

REVOKE ALL ON FUNCTION public.statement_reminder_send(uuid, uuid, int, boolean) FROM PUBLIC, anon, authenticated;

-- The recipe handler: daily, live, one-week catch-up window.
CREATE OR REPLACE FUNCTION public.statement_reminder_run(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.statement_reminder_send(p_agency_id, p_recipe_id, 7, false)
$$;
REVOKE ALL ON FUNCTION public.statement_reminder_run(uuid, uuid) FROM PUBLIC, anon, authenticated;
