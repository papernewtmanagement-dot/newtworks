-- Round the numeric outputs to 2 decimals so the page renders 0.50 rather than 0.50000000.
CREATE OR REPLACE FUNCTION public.get_weekly_cpr_requirements(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, carryover numeric, personal_misses integer, team_misses integer, missed integer, cost numeric, total numeric, modified integer, quotes_discussed integer, paid numeric, owed numeric, net_quotes numeric)
 LANGUAGE plpgsql
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
    SELECT team_id AS tm_id
      FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', v_target_week_start)
    UNION
    SELECT t.id AS tm_id
      FROM public.team t
      JOIN public.weekly_cpr_team_detail dd ON dd.team_member_id = t.id
      JOIN public.weekly_cpr_reports rr ON rr.id = dd.weekly_cpr_report_id
     WHERE t.agency_id           = p_agency_id
       AND t.category             = 'agency'
       AND COALESCE(t.role_level,'') <> 'Owner'
       AND t.is_admin_backoffice  = false
       AND t.is_test_user IS NOT TRUE
       AND rr.agency_id           = p_agency_id
       AND rr.week_ending_date    = p_week_ending_date
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
        (value->>'carryover_input')::numeric     AS carryover_input
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
        m.carryover_input::numeric AS carryover,
        CASE WHEN d.id IS NULL THEN 0 ELSE
          (CASE WHEN COALESCE(d.scorecard_done, false) THEN 0 ELSE 1 END +
           CASE WHEN COALESCE(d.wrapup_done,    false) THEN 0 ELSE 1 END +
           CASE WHEN COALESCE(d.inbox_done,     false) THEN 0 ELSE 1 END +
           CASE WHEN d.code_reds IS NULL OR btrim(d.code_reds) = '' THEN 0
                ELSE (SELECT COUNT(*)
                        FROM regexp_split_to_table(d.code_reds, E'\r?\n') AS ln
                       WHERE btrim(ln) <> '')
           END)
        END::integer AS personal_misses,
        COALESCE((SELECT week_team_misses FROM this_report), 0)::integer AS team_misses,
        COALESCE(d.quotes_discussed, 0)::integer AS quotes_discussed,
        COALESCE(d.quotes_modified, 0)::integer  AS modified,
        CASE
          WHEN COALESCE(d.start_date, t.start_date) IS NULL THEN 1.00
          ELSE (
            CASE
              WHEN GREATEST(1, ((v_loop_week - COALESCE(d.start_date, t.start_date)) / 7) + 1) <= 2 THEN 0.00
              WHEN GREATEST(1, ((v_loop_week - COALESCE(d.start_date, t.start_date)) / 7) + 1) <= 4 THEN 0.20
              WHEN GREATEST(1, ((v_loop_week - COALESCE(d.start_date, t.start_date)) / 7) + 1) <= 8 THEN 0.50
              ELSE 1.00
            END
          )
        END::numeric AS cost
      FROM members m
      JOIN public.team t ON t.id = m.tm_id
      LEFT JOIN public.weekly_cpr_team_detail d
        ON d.weekly_cpr_report_id = (SELECT report_id FROM this_report)
       AND d.team_member_id       = m.tm_id
    ),
    per_person_derived AS (
      SELECT
        tm_id, carryover, personal_misses, team_misses, modified, quotes_discussed, cost,
        (team_misses + personal_misses)::integer                                              AS missed,
        ROUND(((carryover + team_misses + personal_misses + modified) * cost)::numeric, 2)     AS total
      FROM per_person
    ),
    team_totals AS (
      SELECT
        SUM(quotes_discussed)::integer                                              AS team_quotes,
        SUM(carryover)::numeric                                                     AS team_carryover,
        SUM((missed + modified) * cost)::numeric                                    AS team_this_period_new,
        SUM(total)::numeric                                                         AS team_total_debt
      FROM per_person_derived
    ),
    allocated AS (
      SELECT
        ppd.tm_id,
        ppd.carryover, ppd.personal_misses, ppd.team_misses, ppd.missed,
        ppd.cost, ppd.total, ppd.modified, ppd.quotes_discussed,
        ROUND((CASE
          WHEN tt.team_quotes >= tt.team_total_debt
            THEN ppd.total
          WHEN tt.team_quotes >= tt.team_carryover
            THEN ppd.carryover +
                 CASE WHEN tt.team_this_period_new > 0
                      THEN (tt.team_quotes - tt.team_carryover)::numeric
                                 * ((ppd.missed + ppd.modified) * ppd.cost)::numeric
                                 / tt.team_this_period_new
                      ELSE 0 END
          ELSE
            CASE WHEN tt.team_carryover > 0
                 THEN tt.team_quotes::numeric * ppd.carryover::numeric
                            / tt.team_carryover
                 ELSE 0 END
        END)::numeric, 2) AS paid
      FROM per_person_derived ppd
      CROSS JOIN team_totals tt
    )
    SELECT COALESCE(
      jsonb_object_agg(
        a.tm_id::text,
        jsonb_build_object(
          'carryover_input',  ROUND((a.total - a.paid)::numeric, 2),
          'carryover',        ROUND(a.carryover::numeric, 2),
          'personal_misses',  a.personal_misses,
          'team_misses',      a.team_misses,
          'missed',           a.missed,
          'cost',             a.cost,
          'total',            a.total,
          'modified',         a.modified,
          'quotes_discussed', a.quotes_discussed,
          'paid',             a.paid,
          'owed',             ROUND((a.total - a.paid)::numeric, 2),
          'net_quotes',       ROUND((a.quotes_discussed - a.paid)::numeric, 2)
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
    (value->>'carryover')::numeric               AS carryover,
    (value->>'personal_misses')::integer         AS personal_misses,
    (value->>'team_misses')::integer             AS team_misses,
    (value->>'missed')::integer                  AS missed,
    (value->>'cost')::numeric                    AS cost,
    (value->>'total')::numeric                   AS total,
    (value->>'modified')::integer                AS modified,
    (value->>'quotes_discussed')::integer        AS quotes_discussed,
    (value->>'paid')::numeric                    AS paid,
    (value->>'owed')::numeric                    AS owed,
    (value->>'net_quotes')::numeric              AS net_quotes
  FROM jsonb_each(v_state);
END;
$function$;
