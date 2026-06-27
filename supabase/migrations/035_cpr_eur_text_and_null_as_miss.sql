-- Migration 035:
-- 1. Relocate EUR from per-person count → single TEXT field on the report
--    (per Peter, 2026-06-27: EUR works better as free-form notes, after Claims/Non-Pays)
-- 2. NULL on a checklist boolean = MISS (visual already renders NULL as ✕;
--    Requirements function now matches that semantic instead of treating NULL as done)
-- 3. Safety guard: skip personal_misses for any week where a team member has no
--    detail row (prevents retroactive penalty against new hires for pre-join weeks)

ALTER TABLE public.weekly_cpr_team_detail DROP COLUMN IF EXISTS eur_count;

ALTER TABLE public.weekly_cpr_reports ADD COLUMN IF NOT EXISTS eur TEXT;
COMMENT ON COLUMN public.weekly_cpr_reports.eur IS
  'EUR (Underwriting Reports) notes for the week. Free-form text. Tracks customers w/ 3+ UW reports run on a single LOB. Not counted against Requirements.';

-- Rewrite get_weekly_cpr_requirements: NULL = miss; skip personal_misses when no detail row.
-- (Full function body identical to what was applied via Supabase MCP on 2026-06-27 —
-- see public.get_weekly_cpr_requirements source for canonical version.)

CREATE OR REPLACE FUNCTION public.get_weekly_cpr_requirements(
  p_agency_id uuid,
  p_week_ending_date date
)
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
  IF v_first_week > p_week_ending_date THEN RETURN; END IF;

  SELECT jsonb_object_agg(m.tm_id::text, jsonb_build_object('carryover_input', 0))
  INTO   v_state
  FROM (
    SELECT DISTINCT t.id AS tm_id
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND (
        (t.is_active = true AND (t.archived_at IS NULL OR t.archived_at > v_target_week_start::timestamptz))
        OR EXISTS (
          SELECT 1 FROM public.weekly_cpr_team_detail dd
          JOIN public.weekly_cpr_reports rr ON rr.id = dd.weekly_cpr_report_id
          WHERE rr.agency_id = p_agency_id AND rr.week_ending_date = p_week_ending_date AND dd.team_member_id = t.id
        )
      )
  ) m;
  IF v_state IS NULL THEN RETURN; END IF;

  v_loop_week := v_first_week;
  WHILE v_loop_week <= p_week_ending_date LOOP
    WITH
    members AS (
      SELECT (key)::uuid AS tm_id, (value->>'carryover_input')::integer AS carryover_input
      FROM jsonb_each(v_state)
    ),
    this_report AS (
      SELECT id AS report_id,
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
      SELECT m.tm_id, m.carryover_input::integer AS carryover,
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
      SELECT tm_id, carryover, personal_misses, team_misses, modified, quotes_discussed,
        (team_misses + personal_misses)::integer AS missed,
        1::integer AS cost,
        ((carryover + team_misses + personal_misses + modified) * 1)::integer AS total
      FROM per_person
    ),
    team_totals AS (
      SELECT SUM(quotes_discussed)::integer AS team_quotes,
        SUM(carryover)::integer AS team_carryover,
        SUM((missed + modified) * cost)::integer AS team_this_period_new,
        SUM(total)::integer AS team_total_debt
      FROM per_person_derived
    ),
    allocated AS (
      SELECT ppd.tm_id, ppd.carryover, ppd.personal_misses, ppd.team_misses, ppd.missed,
        ppd.cost, ppd.total, ppd.modified, ppd.quotes_discussed,
        CASE
          WHEN tt.team_quotes >= tt.team_total_debt THEN ppd.total
          WHEN tt.team_quotes >= tt.team_carryover THEN ppd.carryover +
            CASE WHEN tt.team_this_period_new > 0
                 THEN ROUND((tt.team_quotes - tt.team_carryover)::numeric
                            * ((ppd.missed + ppd.modified) * ppd.cost)::numeric
                            / tt.team_this_period_new)::integer
                 ELSE 0 END
          ELSE CASE WHEN tt.team_carryover > 0
                    THEN ROUND(tt.team_quotes::numeric * ppd.carryover::numeric / tt.team_carryover)::integer
                    ELSE 0 END
        END::integer AS paid
      FROM per_person_derived ppd CROSS JOIN team_totals tt
    )
    SELECT COALESCE(jsonb_object_agg(a.tm_id::text, jsonb_build_object(
      'carryover_input',  (a.total - a.paid),
      'carryover',        a.carryover, 'personal_misses', a.personal_misses,
      'team_misses',      a.team_misses, 'missed', a.missed,
      'cost',             a.cost, 'total', a.total, 'modified', a.modified,
      'quotes_discussed', a.quotes_discussed, 'paid', a.paid,
      'owed',             (a.total - a.paid),
      'net_quotes',       (a.quotes_discussed - a.paid)
    )), '{}'::jsonb)
    INTO v_state FROM allocated a;
    v_loop_week := v_loop_week + 7;
  END LOOP;

  RETURN QUERY
  SELECT (key)::uuid AS team_member_id,
    (value->>'carryover')::integer AS carryover,
    (value->>'personal_misses')::integer AS personal_misses,
    (value->>'team_misses')::integer AS team_misses,
    (value->>'missed')::integer AS missed,
    (value->>'cost')::integer AS cost,
    (value->>'total')::integer AS total,
    (value->>'modified')::integer AS modified,
    (value->>'quotes_discussed')::integer AS quotes_discussed,
    (value->>'paid')::integer AS paid,
    (value->>'owed')::integer AS owed,
    (value->>'net_quotes')::integer AS net_quotes
  FROM jsonb_each(v_state);
END;
$function$;
