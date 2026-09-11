-- Daily team checklist + CPR weekly audit from ONE item table (Peter 2026-09-11).
--
-- The Daily Wrap-up team items are rows in checklist_items. The team ticks them each
-- workday in daily_checklist_ticks (name + time on every tick, any teammate can tick or
-- untick). The CPR audits the SAME rows once a week in weekly_cpr_checklist, and that
-- audit is the only place a miss costs quotes. The daily tick carries no cost; it is
-- visibility plus a running warning that quotes may be coming.
--
-- History is frozen: weeks ending BEFORE 2026-09-12 keep their eleven legacy boolean
-- columns on weekly_cpr_reports (shareds_done ... bad_data_done) and pay math reads
-- them unchanged. From week ending 2026-09-12 forward get_weekly_cpr_requirements counts
-- team misses from weekly_cpr_checklist against the items in effect that week.

-- ─── Tables ──────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.checklist_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  item_key text NOT NULL,
  title text NOT NULL,
  scope text NOT NULL DEFAULT 'team' CHECK (scope IN ('team', 'personal')),
  sort_order integer NOT NULL DEFAULT 100,
  effective_from date NOT NULL DEFAULT ((now() AT TIME ZONE 'America/Chicago')::date),
  effective_to date,
  legacy_cpr_column text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, item_key)
);
COMMENT ON TABLE public.checklist_items IS
  'Daily Wrap-up checklist items. One row per item; the daily tick list, the kickoff bridge and the CPR weekly audit all read this table, so the three can never drift. effective_from / effective_to are CPR week-ending Saturdays: an item counts for a week when effective_from <= week_ending <= coalesce(effective_to, week_ending).';

CREATE TABLE IF NOT EXISTS public.daily_checklist_ticks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  item_id uuid NOT NULL REFERENCES public.checklist_items(id) ON DELETE CASCADE,
  tick_date date NOT NULL,
  ticked_by uuid REFERENCES public.team(id) ON DELETE SET NULL,
  ticked_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, item_id, tick_date)
);
COMMENT ON TABLE public.daily_checklist_ticks IS
  'One row per team item per Central workday that the team marked done. Who ticked and when. A missing row is an open item. Untick deletes the row. No cost attaches here; the CPR audit (weekly_cpr_checklist) is where a miss costs quotes.';
CREATE INDEX IF NOT EXISTS daily_checklist_ticks_date_idx ON public.daily_checklist_ticks (agency_id, tick_date);

CREATE TABLE IF NOT EXISTS public.weekly_cpr_checklist (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  weekly_cpr_report_id uuid NOT NULL REFERENCES public.weekly_cpr_reports(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.checklist_items(id) ON DELETE CASCADE,
  done boolean NOT NULL DEFAULT false,
  updated_by uuid REFERENCES public.team(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (weekly_cpr_report_id, item_id)
);
COMMENT ON TABLE public.weekly_cpr_checklist IS
  'Peter''s weekly CPR audit of the team checklist, one row per item per report. Missing row = not verified = a miss, exactly as a NULL legacy column counted. Replaces the eleven *_done columns on weekly_cpr_reports for weeks ending 2026-09-12 and later; earlier weeks still read the legacy columns so history never moves.';

-- ─── RLS ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.checklist_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS checklist_items_auth_read ON public.checklist_items;
CREATE POLICY checklist_items_auth_read ON public.checklist_items
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
DROP POLICY IF EXISTS checklist_items_admin_write ON public.checklist_items;
CREATE POLICY checklist_items_admin_write ON public.checklist_items
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin())
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin());

ALTER TABLE public.daily_checklist_ticks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS daily_checklist_ticks_auth_read ON public.daily_checklist_ticks;
CREATE POLICY daily_checklist_ticks_auth_read ON public.daily_checklist_ticks
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
-- Writes go through daily_checklist_tick() only.

ALTER TABLE public.weekly_cpr_checklist ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS weekly_cpr_checklist_auth_read ON public.weekly_cpr_checklist;
CREATE POLICY weekly_cpr_checklist_auth_read ON public.weekly_cpr_checklist
  FOR SELECT TO authenticated
  USING (true);
DROP POLICY IF EXISTS weekly_cpr_checklist_admin_write ON public.weekly_cpr_checklist;
CREATE POLICY weekly_cpr_checklist_admin_write ON public.weekly_cpr_checklist
  FOR ALL TO authenticated
  USING (public.is_agency_admin())
  WITH CHECK (public.is_agency_admin());

-- ─── Seed: the sixteen team items on Daily Wrap-up, page order ───────────────
-- All start with the CPR week ending 2026-09-12. Legacy column mapping is noted for
-- reference only; nothing is backfilled because earlier weeks keep the legacy columns.

INSERT INTO public.checklist_items (agency_id, item_key, title, scope, sort_order, effective_from, legacy_cpr_column) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'kickoff',            'Daily Kickoff & role play held',                                  'team', 10,  DATE '2026-09-12', NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'shared_folders',     'Shared Outlook folders (* and @) handled',                        'team', 20,  DATE '2026-09-12', 'shareds_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'texts',              'Texts handled',                                                   'team', 30,  DATE '2026-09-12', 'texts_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'mail',               'Incoming mail handled',                                           'team', 40,  DATE '2026-09-12', NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'appointments',       'Upcoming appointments verified & reminded',                       'team', 50,  DATE '2026-09-12', 'appts_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'claims',             'Claims: touch tasks set + marked reviewed',                       'team', 60,  DATE '2026-09-12', NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'opp_lists',          'Opportunity Lists 01-14, Missing Phone & Missing Data cleared',   'team', 70,  DATE '2026-09-12', 'new_opps_done, no_phone_done, bad_data_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'sales_tasks',        'All sales tasks worked and completed',                            'team', 80,  DATE '2026-09-12', 'tasks_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'campaign_leads',     '10 campaign leads converted per acquisition team member',         'team', 90,  DATE '2026-09-12', NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'billed_prior_month', 'Auto/fire billed-prior-month campaign worked',                    'team', 100, DATE '2026-09-12', NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'ecrm_hygiene',       'ECRM record hygiene (required fields, onboarding cases, cases closed)', 'team', 110, DATE '2026-09-12', 'no_fu_task_done, cases_done, no_onboarding_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'service_tasks',      'Service tasks completed / canceled / touched & pended',           'team', 120, DATE '2026-09-12', 'tasks_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'production_manager', 'Production Manager check in ECRM (4 PM or later)',                'team', 130, DATE '2026-09-12', NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'deposits',           'Final deposit completed + Close Day',                             'team', 140, DATE '2026-09-12', 'deposits_done'),
  ('126794dd-25ff-47d2-a436-724499733365', 'resumes',            'Resumes verified in the paper.newt.management inbox',             'team', 150, DATE '2026-09-12', NULL),
  ('126794dd-25ff-47d2-a436-724499733365', 'dnc',                'Do Not Call list cleared',                                        'team', 160, DATE '2026-09-12', NULL)
ON CONFLICT (agency_id, item_key) DO NOTHING;

-- ─── Helpers ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.checklist_is_workday(p_agency_id uuid, p_date date)
RETURNS boolean
LANGUAGE sql STABLE
AS $function$
  SELECT EXTRACT(ISODOW FROM p_date) BETWEEN 1 AND 5
     AND public.closed_holiday_name(p_agency_id, p_date) IS NULL;
$function$;

CREATE OR REPLACE FUNCTION public.checklist_prev_workday(p_agency_id uuid, p_date date)
RETURNS date
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_d date := p_date - 1;
  v_i int := 0;
BEGIN
  WHILE v_i < 14 LOOP
    IF public.checklist_is_workday(p_agency_id, v_d) THEN
      RETURN v_d;
    END IF;
    v_d := v_d - 1;
    v_i := v_i + 1;
  END LOOP;
  RETURN NULL;
END;
$function$;

-- Items in effect for a CPR week (week_ending = Saturday), page order.
CREATE OR REPLACE FUNCTION public.checklist_items_for_week(p_agency_id uuid, p_week_ending date)
RETURNS SETOF public.checklist_items
LANGUAGE sql STABLE
AS $function$
  SELECT *
  FROM public.checklist_items i
  WHERE i.agency_id = p_agency_id
    AND i.scope = 'team'
    AND i.effective_from <= p_week_ending
    AND (i.effective_to IS NULL OR i.effective_to >= p_week_ending)
  ORDER BY i.sort_order, i.title;
$function$;

-- Team misses for a CPR week from the audit rows: items in effect that week with no
-- done=true row. Same rule as the legacy columns (NULL counted as a miss).
CREATE OR REPLACE FUNCTION public.cpr_checklist_team_misses(p_agency_id uuid, p_week_ending date)
RETURNS integer
LANGUAGE sql STABLE
AS $function$
  SELECT COUNT(*)::integer
  FROM public.checklist_items_for_week(p_agency_id, p_week_ending) i
  LEFT JOIN public.weekly_cpr_reports r
    ON r.agency_id = p_agency_id AND r.week_ending_date = p_week_ending
  LEFT JOIN public.weekly_cpr_checklist c
    ON c.item_id = i.id AND c.weekly_cpr_report_id = r.id
  WHERE COALESCE(c.done, false) = false;
$function$;

-- ─── Daily tick surface (Daily Wrap-up page card) ────────────────────────────

CREATE OR REPLACE FUNCTION public.daily_checklist_state(p_date date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_me uuid := public.current_team_member_id();
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_day date;
  v_week_end date;
  v_week_start date;
  v_prev date;
  v_leader text;
  v_items jsonb;
  v_carry jsonb;
  v_risk jsonb;
  v_risk_count int;
BEGIN
  v_day := COALESCE(p_date, v_today);
  IF v_day > v_today THEN v_day := v_today; END IF;
  IF NOT public.checklist_is_workday(v_agency, v_day) THEN
    v_day := COALESCE(public.checklist_prev_workday(v_agency, v_day), v_day);
  END IF;
  v_week_end := v_day + (6 - EXTRACT(DOW FROM v_day)::int);
  v_week_start := v_week_end - 6;
  v_prev := public.checklist_prev_workday(v_agency, v_day);

  SELECT COALESCE(NULLIF(t.nickname, ''), t.first_name) INTO v_leader
  FROM public.agency_huddle_config c
  JOIN public.team t ON t.id = c.current_week_leader_team_id
  WHERE c.agency_id = v_agency;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', i.id, 'title', i.title, 'sort_order', i.sort_order,
           'ticked_by', COALESCE(NULLIF(tm.nickname, ''), tm.first_name),
           'ticked_at', k.ticked_at) ORDER BY i.sort_order, i.title), '[]'::jsonb)
  INTO v_items
  FROM public.checklist_items_for_week(v_agency, v_week_end) i
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_day
  LEFT JOIN public.team tm ON tm.id = k.ticked_by;

  -- Carry-forward: the previous workday's items still open.
  IF v_prev IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title) ORDER BY i.sort_order, i.title), '[]'::jsonb)
    INTO v_carry
    FROM public.checklist_items_for_week(v_agency, v_prev + (6 - EXTRACT(DOW FROM v_prev)::int)) i
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
    WHERE k.id IS NULL;
  END IF;

  -- At risk this week: any past workday of this CPR week (Monday .. yesterday) with no tick.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'days', r.days) ORDER BY r.sort_order, r.title), '[]'::jsonb),
         COUNT(*)
  INTO v_risk, v_risk_count
  FROM (
    SELECT i.id, i.title, i.sort_order, jsonb_agg(to_char(d.d, 'Dy') ORDER BY d.d) AS days
    FROM public.checklist_items_for_week(v_agency, v_week_end) i
    CROSS JOIN LATERAL (
      SELECT g::date AS d
      FROM generate_series(v_week_start, v_day - 1, interval '1 day') g
      WHERE public.checklist_is_workday(v_agency, g::date)
    ) d
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = d.d
    WHERE k.id IS NULL
    GROUP BY i.id, i.title, i.sort_order
  ) r;

  RETURN jsonb_build_object(
    'date', v_day,
    'today', v_today,
    'is_today', v_day = v_today,
    'label', to_char(v_day, 'Dy Mon FMDD'),
    'me', v_me,
    'leader', v_leader,
    'week_ending', v_week_end,
    'items', v_items,
    'carry', CASE WHEN v_prev IS NULL THEN NULL
                  ELSE jsonb_build_object('date', v_prev, 'label', to_char(v_prev, 'Dy Mon FMDD'), 'open', COALESCE(v_carry, '[]'::jsonb)) END,
    'at_risk', v_risk,
    'at_risk_count', v_risk_count
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.daily_checklist_tick(p_item_id uuid, p_date date, p_on boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
BEGIN
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'no team member for this login' USING ERRCODE = '42501';
  END IF;
  SELECT t.agency_id INTO v_agency FROM public.team t WHERE t.id = v_me;
  IF p_date IS NULL OR p_date > v_today OR p_date < v_today - 14 THEN
    RAISE EXCEPTION 'tick date must be within the last two weeks' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.checklist_items i WHERE i.id = p_item_id AND i.agency_id = v_agency) THEN
    RAISE EXCEPTION 'unknown checklist item' USING ERRCODE = '22023';
  END IF;
  IF p_on THEN
    INSERT INTO public.daily_checklist_ticks (agency_id, item_id, tick_date, ticked_by, ticked_at)
    VALUES (v_agency, p_item_id, p_date, v_me, now())
    ON CONFLICT (agency_id, item_id, tick_date) DO NOTHING;
  ELSE
    DELETE FROM public.daily_checklist_ticks
    WHERE agency_id = v_agency AND item_id = p_item_id AND tick_date = p_date;
  END IF;
  RETURN jsonb_build_object('ok', true, 'item_id', p_item_id, 'date', p_date, 'on', p_on);
END;
$function$;

-- ─── Kickoff bridge text (morning Telegram + kickoff page) ────────────────────

CREATE OR REPLACE FUNCTION public.render_daily_checklist_bridge(p_agency_id uuid, p_today date)
RETURNS text
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_prev date;
  v_prev_week_end date;
  v_total int;
  v_done int;
  v_open text;
  v_week_end date;
  v_week_start date;
  v_risk int;
  v_text text;
BEGIN
  v_prev := public.checklist_prev_workday(p_agency_id, p_today);
  IF v_prev IS NULL THEN RETURN NULL; END IF;
  v_prev_week_end := v_prev + (6 - EXTRACT(DOW FROM v_prev)::int);

  SELECT COUNT(*), COUNT(k.id),
         string_agg(CASE WHEN k.id IS NULL THEN i.title END, '; ' ORDER BY i.sort_order, i.title)
  INTO v_total, v_done, v_open
  FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end) i
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev;
  IF COALESCE(v_total, 0) = 0 THEN RETURN NULL; END IF;

  v_text := format('📋 Team list %s: %s of %s cleared', to_char(v_prev, 'Dy Mon FMDD'), v_done, v_total);
  IF v_done = v_total THEN
    v_text := v_text || ' ✅';
  ELSE
    v_text := v_text || E'\nOpen: ' || v_open;
  END IF;

  -- Running warning for the CPR week p_today sits in: items with any past workday unticked.
  v_week_end := p_today + (6 - EXTRACT(DOW FROM p_today)::int);
  v_week_start := v_week_end - 6;
  SELECT COUNT(DISTINCT i.id) INTO v_risk
  FROM public.checklist_items_for_week(p_agency_id, v_week_end) i
  CROSS JOIN LATERAL (
    SELECT g::date AS d
    FROM generate_series(v_week_start, p_today - 1, interval '1 day') g
    WHERE public.checklist_is_workday(p_agency_id, g::date)
  ) d
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = d.d
  WHERE k.id IS NULL;
  IF COALESCE(v_risk, 0) > 0 THEN
    v_text := v_text || format(E'\nThis week at risk: %s item%s (+1 quote each, per person, if the CPR confirms it)',
                               v_risk, CASE WHEN v_risk = 1 THEN '' ELSE 's' END);
  END IF;
  RETURN v_text;
END;
$function$;

-- Today's morning Telegram text, exactly as sent, for the kickoff page. Falls back to the
-- most recent morning message when today's has not gone out yet (label carries the date).
CREATE OR REPLACE FUNCTION public.kickoff_morning_message(p_date date DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object('date', r.checkin_date, 'sent_at', r.reminder_sent_at, 'text', r.reminder_text,
                            'is_today', r.checkin_date = COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date))
  FROM public.team_checkin_runs r
  WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND r.checkin_type = 'morning'
    AND r.reminder_text IS NOT NULL
    AND r.checkin_date <= COALESCE(p_date, (now() AT TIME ZONE 'America/Chicago')::date)
  ORDER BY r.checkin_date DESC, r.reminder_sent_at DESC NULLS LAST
  LIMIT 1;
$function$;

-- ─── CPR weekly audit surface ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.cpr_checklist_get(p_report_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid;
  v_week_end date;
  v_workdays jsonb;
  v_items jsonb;
BEGIN
  SELECT agency_id, week_ending_date INTO v_agency, v_week_end
  FROM public.weekly_cpr_reports WHERE id = p_report_id;
  IF v_week_end IS NULL THEN RETURN NULL; END IF;

  SELECT COALESCE(jsonb_agg(to_char(g::date, 'YYYY-MM-DD') ORDER BY g), '[]'::jsonb) INTO v_workdays
  FROM generate_series(v_week_end - 6, v_week_end, interval '1 day') g
  WHERE public.checklist_is_workday(v_agency, g::date);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', i.id, 'title', i.title, 'sort_order', i.sort_order,
      'done', COALESCE(c.done, false),
      'ticks', (SELECT COALESCE(jsonb_object_agg(to_char(k.tick_date, 'YYYY-MM-DD'),
                                jsonb_build_object('by', COALESCE(NULLIF(tm.nickname, ''), tm.first_name), 'at', k.ticked_at)), '{}'::jsonb)
                FROM public.daily_checklist_ticks k
                LEFT JOIN public.team tm ON tm.id = k.ticked_by
                WHERE k.item_id = i.id AND k.tick_date BETWEEN v_week_end - 6 AND v_week_end)
    ) ORDER BY i.sort_order, i.title), '[]'::jsonb)
  INTO v_items
  FROM public.checklist_items_for_week(v_agency, v_week_end) i
  LEFT JOIN public.weekly_cpr_checklist c ON c.item_id = i.id AND c.weekly_cpr_report_id = p_report_id;

  RETURN jsonb_build_object('report_id', p_report_id, 'week_ending', v_week_end, 'workdays', v_workdays, 'items', v_items);
END;
$function$;

CREATE OR REPLACE FUNCTION public.cpr_checklist_save(p_report_id uuid, p_marks jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_key text;
  v_val jsonb;
BEGIN
  IF NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.weekly_cpr_reports WHERE id = p_report_id) THEN
    RAISE EXCEPTION 'unknown CPR report' USING ERRCODE = '22023';
  END IF;
  FOR v_key, v_val IN SELECT key, value FROM jsonb_each(COALESCE(p_marks, '{}'::jsonb)) LOOP
    INSERT INTO public.weekly_cpr_checklist (weekly_cpr_report_id, item_id, done, updated_by, updated_at)
    VALUES (p_report_id, v_key::uuid, COALESCE((v_val #>> '{}')::boolean, false), v_me, now())
    ON CONFLICT (weekly_cpr_report_id, item_id) DO UPDATE
      SET done = EXCLUDED.done, updated_by = EXCLUDED.updated_by, updated_at = now();
  END LOOP;
  RETURN public.cpr_checklist_get(p_report_id);
END;
$function$;

-- ─── Grants ──────────────────────────────────────────────────────────────────

REVOKE ALL ON FUNCTION public.daily_checklist_state(date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.daily_checklist_tick(uuid, date, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.kickoff_morning_message(date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cpr_checklist_get(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cpr_checklist_save(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.daily_checklist_state(date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.daily_checklist_tick(uuid, date, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.kickoff_morning_message(date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cpr_checklist_get(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cpr_checklist_save(uuid, jsonb) TO authenticated, service_role;

-- ─── get_weekly_cpr_requirements: legacy columns before 2026-09-12, audit rows after ──
-- Patched by exact anchor so the rest of the function is untouched. Raises if the
-- anchors have drifted rather than guessing.

DO $do$
DECLARE
  v_def text;
  v_a1 text := $a$        (CASE WHEN COALESCE(shareds_done,       false) THEN 0 ELSE 1 END +$a$;
  v_b1 text := $b$        CASE WHEN v_loop_week >= DATE '2026-09-12'
          THEN public.cpr_checklist_team_misses(p_agency_id, v_loop_week)
          ELSE
        (CASE WHEN COALESCE(shareds_done,       false) THEN 0 ELSE 1 END +$b$;
  v_a2 text := $a$        )::integer AS week_team_misses$a$;
  v_b2 text := $b$        )::integer END AS week_team_misses$b$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_weekly_cpr_requirements';
  IF v_def IS NULL THEN RAISE EXCEPTION 'get_weekly_cpr_requirements not found'; END IF;
  IF position(v_a1 IN v_def) = 0 OR position(v_a2 IN v_def) = 0 THEN
    RAISE EXCEPTION 'get_weekly_cpr_requirements anchors not found; function text drifted';
  END IF;
  IF position('cpr_checklist_team_misses' IN v_def) > 0 THEN
    RAISE NOTICE 'get_weekly_cpr_requirements already patched';
    RETURN;
  END IF;
  v_def := replace(v_def, v_a1, v_b1);
  v_def := replace(v_def, v_a2, v_b2);
  EXECUTE v_def;
END
$do$;

-- ─── Morning reminder: add the checklist bridge (same anchor-guarded patch) ──

DO $do$
DECLARE
  v_def text;
  v_a1 text := $a$  v_commits text;
BEGIN$a$;
  v_b1 text := $b$  v_commits text; v_checklist text;
BEGIN$b$;
  v_a2 text := $a$    IF v_last_eod_date IS NOT NULL AND v_block.encouragement_text IS NOT NULL THEN$a$;
  v_b2 text := $b$    -- Daily team checklist bridge (Peter 2026-09-11): yesterday's open team items
    -- and the running at-risk count for this CPR week. Same text shows on the
    -- Daily Kickoff page through kickoff_morning_message().
    v_checklist := public.render_daily_checklist_bridge(p_agency_id, v_today);
    IF v_checklist IS NOT NULL THEN
      v_text := v_text || E'\n\n' || v_checklist;
    END IF;

    IF v_last_eod_date IS NOT NULL AND v_block.encouragement_text IS NOT NULL THEN$b$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'team_checkin_send_reminder';
  IF v_def IS NULL THEN RAISE EXCEPTION 'team_checkin_send_reminder not found'; END IF;
  IF position('render_daily_checklist_bridge' IN v_def) > 0 THEN
    RAISE NOTICE 'team_checkin_send_reminder already patched';
    RETURN;
  END IF;
  IF position(v_a1 IN v_def) = 0 OR position(v_a2 IN v_def) = 0 THEN
    RAISE EXCEPTION 'team_checkin_send_reminder anchors not found; function text drifted';
  END IF;
  v_def := replace(v_def, v_a1, v_b1);
  v_def := replace(v_def, v_a2, v_b2);
  EXECUTE v_def;
END
$do$;
