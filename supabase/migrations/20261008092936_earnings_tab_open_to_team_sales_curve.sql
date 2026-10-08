-- Earnings tab was opened to the team (Peter 2026-09-15; Sales curve only 2026-10-05;
-- Team view 2026-10-07) but the database still gated the projection to the owner, so every
-- non-owner got 'Not authorized'. Teammates now load the Sales curve; Retention and Life
-- Specialist and the bonus-pool dollar figures stay owner-only, enforced here, not just in the app.
DO $mig$
DECLARE d text;
BEGIN
  -- 1. Gate: also passes inside compute_role_earnings_projection's own call to the inputs.
  d := pg_get_functiondef('public.pay_projection_caller_ok'::regproc);
  IF position('pay_projection_internal' in d) = 0 THEN
    d := replace(d, E'  RETURN COALESCE(public.current_app_user_role() = ''owner'', false);',
      E'  IF current_setting(''newtworks.pay_projection_internal'', true) = ''on'' THEN\n    RETURN true;   -- inside compute_role_earnings_projection only (set and cleared there)\n  END IF;\n  RETURN COALESCE(public.current_app_user_role() = ''owner'', false);');
    EXECUTE d;
  END IF;

  -- 2. Projection: staff can call; non-owners get the Sales role only and no pool dollars.
  d := pg_get_functiondef('public.compute_role_earnings_projection'::regproc);
  IF position('v_owner' in d) = 0 THEN
    d := replace(d, E'DECLARE\n  v_inputs          jsonb;', E'DECLARE\n  v_owner           boolean;\n  v_out             jsonb;\n  v_inputs          jsonb;');
    d := replace(d, E'  PERFORM public.require_login(''staff'');\n  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);',
      E'  PERFORM public.require_login(''staff'');\n  -- Teammates see the Sales curve (Peter 2026-09-15, 2026-10-05); the owner sees all three\n  -- curves and the pool dollars. The flag lets the owner-only inputs run inside this call only.\n  v_owner := public.pay_projection_caller_ok();\n  PERFORM set_config(''newtworks.pay_projection_internal'', ''on'', true);\n  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);\n  PERFORM set_config(''newtworks.pay_projection_internal'', ''off'', true);');
    d := replace(d, E'  RETURN jsonb_build_object(\n    ''agency_id'', p_agency_id,',
      E'  IF NOT v_owner THEN\n    SELECT COALESCE(jsonb_agg(e), ''[]''::jsonb) INTO v_roles\n      FROM jsonb_array_elements(v_roles) e WHERE e->>''role_key'' = ''sales'';\n  END IF;\n\n  v_out := jsonb_build_object(\n    ''agency_id'', p_agency_id,');
    d := replace(d, E'    )\n  );\nEND;\n$function$',
      E'    )\n  );\n  IF NOT v_owner THEN\n    v_out := jsonb_set(v_out, ''{assumptions}'', (v_out->''assumptions'')\n      - ARRAY[''pool_basis_annual'',''weekly_bonus_pool'',''annual_sales_points_pools'',''annual_retention_pool'',''pool_pct_used'']);\n  END IF;\n  RETURN v_out;\nEND;\n$function$');
    IF position('RETURN v_out' in d) = 0 OR position('v_owner := ' in d) = 0 OR position('v_out := jsonb_build_object' in d) = 0 THEN
      RAISE EXCEPTION 'compute_role_earnings_projection patch did not apply cleanly';
    END IF;
    EXECUTE d;
  END IF;

  -- 3. Year-one path: the published Sales ladder rungs, shown with the Sales curve.
  d := pg_get_functiondef('public.year_one_path_to_100k'::regproc);
  d := replace(d, E'  IF NOT public.pay_projection_caller_ok() THEN\n    RAISE EXCEPTION ''Not authorized: pay projections are admin only'';\n  END IF;\n', '');
  EXECUTE d;
END
$mig$;
