-- Replaces the leaderboard block inside audit_weekly_leaderboard_crossings. It used to wipe
-- every row for a category and re-insert the best 3, which destroyed whatever fell to 4th.
-- Now a record-setting performance is written to the append-only leaderboard_entries ledger
-- and the board is rebuilt from it at the end of the run. Same board, nothing lost, and a
-- corrected figure corrects the board because the entry updates in place.
DO $do$
DECLARE
  d text;
  s int;
  e int;
  v_new text;
  v_anchor text := E'\n  RETURN jsonb_build_object(';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'audit_weekly_leaderboard_crossings';

  s := position('      IF r.the_value > COALESCE(bronze_val, 0) THEN' IN d);
  IF s = 0 THEN RAISE EXCEPTION 'leaderboard block start not found'; END IF;

  e := position(E'    END LOOP;' IN substr(d, s));
  IF e = 0 THEN RAISE EXCEPTION 'inner loop end not found'; END IF;
  e := s + e - 1;

  v_new :=
'      IF r.the_value > COALESCE(bronze_val, 0) THEN
        -- Append-only ledger. One entry per person per category per period, so re-running the
        -- same week updates the entry in place instead of adding a second one. The board is
        -- rebuilt from this ledger at the end of the run, which means a record that gets
        -- deleted lets the record it displaced come straight back (Peter 2026-09-11).
        INSERT INTO public.leaderboard_entries
          (agency_id, category, team_member_id, record_value, record_period_label, record_week_ending)
        VALUES (p_agency_id, cfg.category, r.team_member_id, r.the_value, period_lbl,
                CASE WHEN cfg.category = ''quarter_sp'' THEN NULL ELSE p_week_end_date END)
        ON CONFLICT (agency_id, category, team_member_id, record_period_label)
        DO UPDATE SET record_value       = EXCLUDED.record_value,
                      record_week_ending = EXCLUDED.record_week_ending,
                      set_at             = now();
        v_leaderboard_updates := v_leaderboard_updates + 1;
      END IF;
';

  d := substr(d, 1, s - 1) || v_new || substr(d, e);

  IF (length(d) - length(replace(d, v_anchor, ''))) / length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'return anchor did not match exactly once';
  END IF;
  d := replace(d, v_anchor,
    E'\n  PERFORM public.rebuild_leaderboards_from_entries(p_agency_id);\n' || v_anchor);

  EXECUTE d;
END
$do$;