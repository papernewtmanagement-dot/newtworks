-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-01 19:12:18 UTC (ledger name: cpr_functions_exclude_admin_backoffice_pt1) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260701191218.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Patch: exclude is_admin_backoffice=true team rows from CPR requirement/hours/prefill queries.
-- Marie (Peter's wife) must not appear in any CPR line, requirement count, hours row, or activity row.

-- 1) get_weekly_cpr_requirements — snapshot query only
CREATE OR REPLACE FUNCTION public.get_weekly_cpr_requirements(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, carryover integer, personal_misses integer, team_misses integer, missed integer, cost integer, total integer, modified integer, quotes_discussed integer, paid integer, owed integer, net_quotes integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_cycle_start       date;
  v_first_week        date;
  v_loop_week         date;
  v_target_week_start date := p_week_ending_date - 6;
  v_state             jsonb;
BEGIN
  SELECT (ci.cycle_start)::date INTO v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_ending_date) ci;

  v_first_week := v_cycle_start + 6;

  IF v_first_week > p_week_ending_date THEN
    RETURN;
  END IF;

  SELECT jsonb_object_agg(m.tm_id::text, jsonb_build_object('carryover_input', 0))
  INTO   v_state
  FROM (
    SELECT DISTINCT t.id AS tm_id
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND t.is_admin_backoffice = false  -- 2026-07-01: exclude Marie/admin_backoffice rows
      AND (
        (t.is_active = true AND (t.archived_at IS NULL OR t.archived_at > v_target_week_start::timestamptz))
        OR EXISTS (
          SELECT 1
          FROM public.weekly_cpr_team_detail dd
          JOIN public.weekly_cpr_reports rr ON rr.id = dd.weekly_cpr_report_id
          WHERE rr.agency_id        = p_agency_id
            AND rr.week_ending_date = p_week_ending_date
            AND dd.team_member_id   = t.id
        )
      )
  ) m;

  IF v_state IS NULL THEN
    RETURN;
  END IF;

  v_loop_week := v_first_week;

  WHILE v_loop_week <= p_week_ending_date LOOP
    WITH
    members AS (
      SELECT
        (key)::uuid                              AS tm_id,
        (value->>'carryover_input')::integer     AS carryover_input
      FROM jsonb_each(v_state)
    ),
    this_report AS (
      SELECT
        id AS report_id,
        (CASE WHEN COALESCE(shareds_done,       false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(texts_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(deposits_done,      false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(appts_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(tasks_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(cases_done,         false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_fu_task_done,    false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(new_opps_done,      false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_onboarding_done, false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_phone_done,      false) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(bad_data_done,      false) THEN 0 ELSE 1 END
        )::integer AS week_team_misses
      FROM public.weekly_cpr_reports
      WHERE agency_id = p_agency_id AND week_ending_date = v_loop_week
    ),
    per_person AS (
      SELECT
        m.tm_id,
        m.carryover_input::integer AS carryover,
        CASE WHEN d.id IS NULL THEN 0 ELSE
          (CASE WHEN COALESCE(d.cpr_reply_done, false) THEN 0 ELSE 1 END +
           CASE WHEN COALESCE(d.wrapup_done,    false) THEN 0 ELSE 1 END +
           CASE WHEN COALESCE(d.inbox_done,     false) THEN 0 ELSE 1 END)
        END::integer AS personal_misses,
        COALESCE((SELECT week_team_misses FROM this_report), 0)::integer AS team_misses,
        COALESCE(d.quotes_discussed, 0)::integer AS quotes_discussed,
        COALESCE(d.quotes_modified, 0)::integer  AS modified
      FROM members m
      LEFT JOIN public.weekly_cpr_team_detail d
        ON d.weekly_cpr_report_id = (SELECT report_id FROM this_report)
       AND d.team_member_id       = m.tm_id
    ),
    per_person_derived AS (
      SELECT
        tm_id, carryover, personal_misses, team_misses, modified, quotes_discussed,
        (team_misses + personal_misses)::integer                                   AS missed,
        1::integer                                                                  AS cost,
        ((carryover + team_misses + personal_misses + modified) * 1)::integer       AS total
      FROM per_person
    ),
    team_totals AS (
      SELECT
        SUM(quotes_discussed)::integer                                              AS team_quotes,
        SUM(carryover)::integer                                                     AS team_carryover,
        SUM((missed + modified) * cost)::integer                                    AS team_this_period_new,
        SUM(total)::integer                                                         AS team_total_debt
      FROM per_person_derived
    ),
    allocated AS (
      SELECT
        ppd.tm_id,
        ppd.carryover, ppd.personal_misses, ppd.team_misses, ppd.missed,
        ppd.cost, ppd.total, ppd.modified, ppd.quotes_discussed,
        CASE
          WHEN tt.team_quotes >= tt.team_total_debt
            THEN ppd.total
          WHEN tt.team_quotes >= tt.team_carryover
            THEN ppd.carryover +
                 CASE WHEN tt.team_this_period_new > 0
                      THEN ROUND((tt.team_quotes - tt.team_carryover)::numeric
                                 * ((ppd.missed + ppd.modified) * ppd.cost)::numeric
                                 / tt.team_this_period_new)::integer
                      ELSE 0 END
          ELSE
            CASE WHEN tt.team_carryover > 0
                 THEN ROUND(tt.team_quotes::numeric * ppd.carryover::numeric
                            / tt.team_carryover)::integer
                 ELSE 0 END
        END::integer AS paid
      FROM per_person_derived ppd
      CROSS JOIN team_totals tt
    )
    SELECT COALESCE(
      jsonb_object_agg(
        a.tm_id::text,
        jsonb_build_object(
          'carryover_input',  (a.total - a.paid),
          'carryover',        a.carryover,
          'personal_misses',  a.personal_misses,
          'team_misses',      a.team_misses,
          'missed',           a.missed,
          'cost',             a.cost,
          'total',            a.total,
          'modified',         a.modified,
          'quotes_discussed', a.quotes_discussed,
          'paid',             a.paid,
          'owed',             (a.total - a.paid),
          'net_quotes',       (a.quotes_discussed - a.paid)
        )
      ),
      '{}'::jsonb
    )
    INTO v_state
    FROM allocated a;

    v_loop_week := v_loop_week + 7;
  END LOOP;

  RETURN QUERY
  SELECT
    (key)::uuid                                  AS team_member_id,
    (value->>'carryover')::integer               AS carryover,
    (value->>'personal_misses')::integer         AS personal_misses,
    (value->>'team_misses')::integer             AS team_misses,
    (value->>'missed')::integer                  AS missed,
    (value->>'cost')::integer                    AS cost,
    (value->>'total')::integer                   AS total,
    (value->>'modified')::integer                AS modified,
    (value->>'quotes_discussed')::integer        AS quotes_discussed,
    (value->>'paid')::integer                    AS paid,
    (value->>'owed')::integer                    AS owed,
    (value->>'net_quotes')::integer              AS net_quotes
  FROM jsonb_each(v_state);
END;
$function$;

-- 2) prefill_weekly_cpr_form
CREATE OR REPLACE FUNCTION public.prefill_weekly_cpr_form(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_report_id        uuid;
  v_inserted_details int := 0;
  v_existing_details int := 0;
  m                  record;
  v_week_start       date := p_week_ending_date - 6;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date)
    VALUES (p_agency_id, p_week_ending_date)
    RETURNING id INTO v_report_id;
  END IF;

  FOR m IN
    SELECT t.id
    FROM public.team t
    WHERE t.agency_id   = p_agency_id
      AND t.category    = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND t.is_admin_backoffice = false  -- 2026-07-01: exclude admin_backoffice
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)
    ORDER BY t.hire_date, t.last_name
  LOOP
    INSERT INTO public.weekly_cpr_team_detail (
      agency_id, weekly_cpr_report_id, team_member_id
    )
    VALUES (p_agency_id, v_report_id, m.id)
    ON CONFLICT (weekly_cpr_report_id, team_member_id) DO NOTHING;

    IF FOUND THEN
      v_inserted_details := v_inserted_details + 1;
    ELSE
      v_existing_details := v_existing_details + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'report_id',         v_report_id,
    'inserted_details',  v_inserted_details,
    'existing_details',  v_existing_details,
    'note',              'Checklist booleans, carryover, missed, cost, total, hours computed at runtime — not stored. Booleans default NULL = unchecked until marked.'
  );
END;
$function$;

-- 3) render_cpr_personal_checklist_html — defense-in-depth
CREATE OR REPLACE FUNCTION public.render_cpr_personal_checklist_html(p_agency_id uuid, p_week_ending_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_rows text;
BEGIN
  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.cpr_reply_done = true THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               WHEN d.cpr_reply_done = false THEN '<span style="color:#dc2626;font-weight:700">✕</span>'
               ELSE '<span style="color:#cbd5e1">—</span>' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.wrapup_done = true THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               WHEN d.wrapup_done = false THEN '<span style="color:#dc2626;font-weight:700">✕</span>'
               ELSE '<span style="color:#cbd5e1">—</span>' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.inbox_done = true THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               WHEN d.inbox_done = false THEN '<span style="color:#dc2626;font-weight:700">✕</span>'
               ELSE '<span style="color:#cbd5e1">—</span>' END
       || '</td></tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_rows
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  JOIN public.team t ON t.id = d.team_member_id
  WHERE r.agency_id = p_agency_id
    AND r.week_ending_date = p_week_ending_date
    AND t.category = 'agency'
    AND COALESCE(t.role_level,'') <> 'Owner'
    AND t.is_admin_backoffice = false;  -- 2026-07-01: defense-in-depth

  RETURN
       '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Person</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">CPR Reply</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Wrap-up</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Inbox</th>'
    || '</tr></thead><tbody>' || COALESCE(v_rows,'') || '</tbody></table>';
END;
$function$;
