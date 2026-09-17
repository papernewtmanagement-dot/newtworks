-- Peter 2026-09-17: on the checklist, only what is unticked TODAY matters.
-- The "this week at risk" roll-up of earlier days comes out of
-- daily_checklist_state entirely - it is not computed and not returned.
DO $mig$
DECLARE
  v_def text;
  v_new text;
  v_block text;
  v_tail text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'daily_checklist_state';

  IF v_def IS NULL THEN RAISE EXCEPTION 'daily_checklist_state not found'; END IF;

  v_block := '  SELECT COALESCE(jsonb_agg(jsonb_build_object(''id'', r.id, ''title'', r.title, ''days'', r.days) ORDER BY r.sort_order, r.title), ''[]''::jsonb),
         COUNT(*)
  INTO v_risk, v_risk_count
  FROM (
    SELECT i.id, i.title, i.sort_order, jsonb_agg(to_char(d.d, ''Dy'') ORDER BY d.d) AS days
    FROM public.checklist_items_for_week(v_agency, v_week_end) i
    CROSS JOIN LATERAL (
      SELECT g::date AS d
      FROM generate_series(v_week_start, v_day - 1, interval ''1 day'') g
      WHERE public.checklist_is_workday(v_agency, g::date)
    ) d
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = d.d
    WHERE k.id IS NULL
    GROUP BY i.id, i.title, i.sort_order
  ) r;

';

  v_tail := ' END,
    ''at_risk'', v_risk,
    ''at_risk_count'', v_risk_count
  );';

  IF position(v_block in v_def) = 0 THEN RAISE EXCEPTION 'at-risk query block not found'; END IF;
  IF position(v_tail in v_def) = 0 THEN RAISE EXCEPTION 'at-risk json tail not found'; END IF;

  v_new := replace(v_def, v_block, '');
  v_new := replace(v_new, v_tail, ' END
  );');
  v_new := replace(v_new, '  v_risk jsonb;
  v_risk_count int;
', '');

  IF position('at_risk' in v_new) > 0 OR position('v_risk' in v_new) > 0 THEN
    RAISE EXCEPTION 'at-risk references still present after rewrite';
  END IF;

  EXECUTE v_new;
END
$mig$;
