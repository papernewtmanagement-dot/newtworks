-- Surfaces the P&C / life split, the tier counts, and the unit counts behind them
-- on each person's sales object. Read straight off the sp jsonb the one production
-- calculator already returns. No new maths anywhere.
DO $mig$
DECLARE
  v_def text;
  v_reported_old text := E'          ''pc_rate'', NULL::numeric, ''lh_rate'', NULL::numeric,\n';
  v_reported_new text := E'          ''pc_rate'', NULL::numeric, ''lh_rate'', NULL::numeric,\n'
                      || E'          ''pc_points'', NULL::numeric, ''lh_points'', NULL::numeric,\n'
                      || E'          ''pc_premium'', NULL::numeric, ''lh_premium'', NULL::numeric,\n'
                      || E'          ''tiers'', NULL::jsonb, ''units'', NULL::jsonb,\n';
  v_live_old text := E'        ''pc_rate'', (s.cur->''rates''->>''pc_rate_capped'')::numeric, ''lh_rate'', (s.cur->''rates''->>''lh_rate_capped'')::numeric,\n';
  v_live_new text := E'        ''pc_rate'', (s.cur->''rates''->>''pc_rate_capped'')::numeric, ''lh_rate'', (s.cur->''rates''->>''lh_rate_capped'')::numeric,\n'
                  || E'        ''pc_points'', COALESCE((s.cur->''commission''->>''pc_commission'')::numeric, 0),\n'
                  || E'        ''lh_points'', COALESCE((s.cur->''commission''->>''lh_commission'')::numeric, 0),\n'
                  || E'        ''pc_premium'', COALESCE((s.cur->''commission''->>''pc_premium_base'')::numeric, 0),\n'
                  || E'        ''lh_premium'', COALESCE((s.cur->''commission''->>''lh_premium_base'')::numeric, 0),\n'
                  || E'        ''tiers'', COALESCE(s.cur->''tiers'', ''{}''::jsonb),\n'
                  || E'        ''units'', COALESCE(s.cur->''units'', ''{}''::jsonb),\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position(v_reported_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'reported-branch sales line not found - another thread changed rp_week_scoreboard_for';
  END IF;
  IF position(v_live_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'live-branch sales line not found - another thread changed rp_week_scoreboard_for';
  END IF;
  IF position(v_live_new IN v_def) > 0 THEN
    RAISE NOTICE 'already applied, nothing to do';
    RETURN;
  END IF;

  v_def := replace(v_def, v_reported_old, v_reported_new);
  v_def := replace(v_def, v_live_old, v_live_new);
  EXECUTE v_def;
END $mig$;
