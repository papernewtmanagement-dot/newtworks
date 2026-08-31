-- Peter directive 2026-08-31: in the team status block, a CLOSED week reads the settled
-- weekly_cpr_team_detail rows; the LIVE week keeps reading team_checkins.
-- Monday's board is labelled "last week close" but was rendering each person's
-- self-reported check-in numbers for a week that had already been corrected.
-- The Win-the-Week panel below the per-person lines is always about the live week
-- and is deliberately left alone.

DO $mig$
DECLARE
  v_src text;
  v_new text;
  v_hits int;
  r record;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'render_team_status_block';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'render_team_status_block not found';
  END IF;

  FOR r IN
    SELECT * FROM (VALUES
      -- 1. declare the flag
      (1,
       '  v_totals record;',
       '  v_totals record;' || E'\n' ||
       '  v_week_closed boolean;'),

      -- 2. decide closed vs live, right after the display cycle is resolved
      (2,
       '  v_display_week_start := v_display_cycle.week_ending_saturday - 6;',
       '  v_display_week_start := v_display_cycle.week_ending_saturday - 6;' || E'\n\n' ||
       '  -- Peter directive 2026-08-31: once the displayed week is no longer the live' || E'\n' ||
       '  -- Win-the-Week week AND its CPR outcome has been written, the per-person lines' || E'\n' ||
       '  -- read the settled weekly_cpr_team_detail rows instead of the self-reported' || E'\n' ||
       '  -- check-ins. The live week keeps reading check-ins - nothing else exists yet.' || E'\n' ||
       '  v_week_closed := v_display_cycle.week_ending_saturday < v_wtw_cycle.week_ending_saturday' || E'\n' ||
       '                   AND EXISTS (' || E'\n' ||
       '                     SELECT 1 FROM public.weekly_cpr_reports r0' || E'\n' ||
       '                     WHERE r0.agency_id = p_agency_id' || E'\n' ||
       '                       AND r0.week_ending_date = v_display_cycle.week_ending_saturday' || E'\n' ||
       '                       AND r0.won_the_week IS NOT NULL' || E'\n' ||
       '                   );'),

      -- 3. add the settled-rows CTE and its columns
      (3,
       '      ORDER BY tc.team_id, tc.received_at DESC' || E'\n' ||
       '    )' || E'\n' ||
       '    SELECT e.team_id, e.display_name, e.first_name,' || E'\n' ||
       '      cp.quotes_week AS cur_quotes, cp.sales_points_quarter AS cur_sales,',
       '      ORDER BY tc.team_id, tc.received_at DESC' || E'\n' ||
       '    ),' || E'\n' ||
       '    cpr AS (' || E'\n' ||
       '      SELECT d.team_member_id AS team_id, d.quotes_discussed, d.sales_points' || E'\n' ||
       '      FROM public.weekly_cpr_team_detail d' || E'\n' ||
       '      JOIN public.weekly_cpr_reports r1 ON r1.id = d.weekly_cpr_report_id' || E'\n' ||
       '      WHERE r1.agency_id = p_agency_id' || E'\n' ||
       '        AND r1.week_ending_date = v_display_cycle.week_ending_saturday' || E'\n' ||
       '    )' || E'\n' ||
       '    SELECT e.team_id, e.display_name, e.first_name,' || E'\n' ||
       '      cd.team_id AS cpr_team_id,' || E'\n' ||
       '      cd.quotes_discussed AS cpr_quotes, cd.sales_points AS cpr_sales,' || E'\n' ||
       '      cp.quotes_week AS cur_quotes, cp.sales_points_quarter AS cur_sales,'),

      -- 4. join it
      (4,
       '    LEFT JOIN carried c ON c.team_id = e.team_id',
       '    LEFT JOIN carried c ON c.team_id = e.team_id' || E'\n' ||
       '    LEFT JOIN cpr cd ON cd.team_id = e.team_id'),

      -- 5. render the settled row first when the week is closed
      (5,
       '  LOOP' || E'\n' ||
       '    IF v_row.cur_quotes IS NOT NULL THEN',
       '  LOOP' || E'\n' ||
       '    IF v_week_closed AND v_row.cpr_team_id IS NOT NULL THEN' || E'\n' ||
       '      v_text := v_text || ''• '' || v_row.display_name || '': ''' || E'\n' ||
       '        || COALESCE(v_row.cpr_quotes, 0)::text || ''/''' || E'\n' ||
       '        || to_char(COALESCE(v_row.cpr_sales, 0), ''FM999G999G999'') || E''\n'';' || E'\n' ||
       '      v_fresh := v_fresh + 1;' || E'\n' ||
       '    ELSIF v_row.cur_quotes IS NOT NULL THEN')
    ) AS t(step, old_txt, new_txt)
    ORDER BY step
  LOOP
    v_hits := (length(v_src) - length(replace(v_src, r.old_txt, ''))) / length(r.old_txt);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION 'step %: expected exactly 1 match, found %', r.step, v_hits;
    END IF;
    v_src := replace(v_src, r.old_txt, r.new_txt);
  END LOOP;

  EXECUTE v_src;
  RAISE NOTICE 'render_team_status_block patched';
END
$mig$;
