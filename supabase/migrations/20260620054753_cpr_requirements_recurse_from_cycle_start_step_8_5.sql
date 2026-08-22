-- Step 8.5: rewrite get_weekly_cpr_requirements to recurse from cycle start.
-- No longer reads weekly_cpr_team_detail.owed; carryover walks forward from
-- cycle_start (where it = 0 for everyone). Once verified, the Owed column
-- can be dropped from weekly_cpr_team_detail.

CREATE OR REPLACE FUNCTION public.get_weekly_cpr_requirements(
  p_agency_id uuid,
  p_week_ending_date date
)
RETURNS TABLE(
  team_member_id uuid,
  carryover integer,
  personal_misses integer,
  team_misses integer,
  missed integer,
  cost integer,
  total integer,
  modified integer,
  quotes_discussed integer,
  paid integer,
  owed integer,
  net_quotes integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cycle_start       date;
  v_first_week        date;
  v_loop_week         date;
  v_target_week_start date := p_week_ending_date - 6;
BEGIN
  -- Find the 13-week cycle that contains the target week
  SELECT (ci.cycle_start)::date INTO v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_ending_date) ci;

  -- cycle_anchor is a Sunday; the cycle's first week-ending Saturday is +6 days
  v_first_week := v_cycle_start + 6;

  -- Defensive: if target falls before this cycle starts, return empty
  IF v_first_week > p_week_ending_date THEN
    RETURN;
  END IF;

  -- Working state table for the loop (auto-dropped at txn end; truncate per call)
  CREATE TEMP TABLE IF NOT EXISTS _cpr_state (
    team_member_id   uuid PRIMARY KEY,
    carryover_input  integer NOT NULL DEFAULT 0,
    carryover        integer NOT NULL DEFAULT 0,
    personal_misses  integer NOT NULL DEFAULT 0,
    team_misses      integer NOT NULL DEFAULT 0,
    missed           integer NOT NULL DEFAULT 0,
    cost             integer NOT NULL DEFAULT 1,
    total            integer NOT NULL DEFAULT 0,
    modified         integer NOT NULL DEFAULT 0,
    quotes_discussed integer NOT NULL DEFAULT 0,
    paid             integer NOT NULL DEFAULT 0,
    owed             integer NOT NULL DEFAULT 0,
    net_quotes       integer NOT NULL DEFAULT 0
  ) ON COMMIT DROP;
  TRUNCATE _cpr_state;

  -- Seed team members per snapshot policy at TARGET week start:
  --   on the team Monday morning of target week, OR has a detail row for target
  INSERT INTO _cpr_state (team_member_id)
  SELECT DISTINCT t.id
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.category = 'agency'
    AND COALESCE(t.role_level, '') <> 'Owner'
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
    );

  v_loop_week := v_first_week;

  -- Walk forward from week 1 of cycle to target week.
  -- Each iteration: compute this week's requirements using carryover_input
  -- from prior iteration, then copy this week's owed into carryover_input
  -- for the next iteration.
  WHILE v_loop_week <= p_week_ending_date LOOP
    WITH this_report AS (
      SELECT
        id AS report_id,
        (CASE WHEN COALESCE(shareds_done,       true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(texts_done,         true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(deposits_done,      true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(appts_done,         true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(tasks_done,         true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(cases_done,         true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_fu_task_done,    true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(new_opps_done,      true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_onboarding_done, true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(no_phone_done,      true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(bad_data_done,      true) THEN 0 ELSE 1 END
        )::integer AS team_misses
      FROM public.weekly_cpr_reports
      WHERE agency_id = p_agency_id AND week_ending_date = v_loop_week
    ),
    per_person AS (
      SELECT
        s.team_member_id,
        s.carryover_input::integer AS carryover,
        (CASE WHEN COALESCE(d.cpr_reply_done, true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(d.wrapup_done,    true) THEN 0 ELSE 1 END +
         CASE WHEN COALESCE(d.inbox_done,     true) THEN 0 ELSE 1 END
        )::integer AS personal_misses,
        COALESCE((SELECT team_misses FROM this_report), 0)::integer AS team_misses,
        COALESCE(d.quotes_discussed, 0)::integer AS quotes_discussed,
        COALESCE(d.quotes_modified, 0)::integer   AS modified
      FROM _cpr_state s
      LEFT JOIN public.weekly_cpr_team_detail d
        ON d.weekly_cpr_report_id = (SELECT report_id FROM this_report)
       AND d.team_member_id       = s.team_member_id
    ),
    per_person_derived AS (
      SELECT
        team_member_id, carryover, personal_misses, team_misses,
        modified, quotes_discussed,
        (team_misses + personal_misses)::integer AS missed,
        1::integer                                AS cost,
        (carryover + (team_misses + personal_misses) * 1)::integer AS total
      FROM per_person
    ),
    team_totals AS (
      SELECT
        SUM(quotes_discussed)::integer                          AS team_quotes,
        SUM(carryover)::integer                                 AS team_carryover,
        SUM(missed * cost)::integer                             AS team_missed_cost,
        (SUM(carryover) + SUM(missed * cost))::integer          AS team_total_debt
      FROM per_person_derived
    ),
    allocated AS (
      SELECT
        ppd.team_member_id,
        ppd.carryover, ppd.personal_misses, ppd.team_misses, ppd.missed, ppd.cost, ppd.total,
        ppd.modified, ppd.quotes_discussed,
        CASE
          WHEN tt.team_quotes >= tt.team_total_debt
            THEN ppd.total
          WHEN tt.team_quotes >= tt.team_carryover
            THEN ppd.carryover +
                 CASE WHEN tt.team_missed_cost > 0
                      THEN ROUND((tt.team_quotes - tt.team_carryover)::numeric
                                 * (ppd.missed * ppd.cost)::numeric
                                 / tt.team_missed_cost)::integer
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
    UPDATE _cpr_state s
    SET
      carryover        = a.carryover,
      personal_misses  = a.personal_misses,
      team_misses      = a.team_misses,
      missed           = a.missed,
      cost             = a.cost,
      total            = a.total,
      modified         = a.modified,
      quotes_discussed = a.quotes_discussed,
      paid             = a.paid,
      owed             = (a.total + a.modified - a.paid)::integer,
      net_quotes       = (a.quotes_discussed - a.total - a.modified)::integer
    FROM allocated a
    WHERE s.team_member_id = a.team_member_id;

    -- This week's owed becomes next week's carryover_input
    UPDATE _cpr_state SET carryover_input = owed;

    v_loop_week := v_loop_week + 7;
  END LOOP;

  RETURN QUERY
  SELECT
    s.team_member_id, s.carryover, s.personal_misses, s.team_misses,
    s.missed, s.cost, s.total, s.modified, s.quotes_discussed,
    s.paid, s.owed, s.net_quotes
  FROM _cpr_state s;
END;
$function$;

-- Grants unchanged from prior version
GRANT EXECUTE ON FUNCTION public.get_weekly_cpr_requirements(uuid, date) TO authenticated, anon;
