-- The Team > Payroll tab was always showing computed figures: pay from the
-- configured rate, bonuses from the CPR. The CPR pool math already switches to
-- the real paycheck once the payroll summary lands (payroll_detail), so the two
-- pages drifted apart for any week that had been paid.
--
-- team_payroll_week now does the same: when a payroll run exists for the week,
-- every money column reads the frozen paycheck line items and the row is flagged
-- from_payroll. Before payroll transmits, it falls back to the computed figures
-- exactly as before. Item keys verified against real SurePayroll summaries:
-- SALARY, REGULAR, HOURLY, PTO and "- O/TIME" make up pay; 1Comm, 2Team, 3Market,
-- 4Goals and 5Manage are the bonus codes; "LIFE *" is the life stipend.
-- Deductions are not carried in raw_earnings, so take_out keeps reading the
-- standing lines on team_payroll_lines.

DO $mig$
DECLARE
  v_def text;
  v_old_cte text := $a$  )
  SELECT COALESCE(jsonb_agg(x ORDER BY pay_ord, last_nm, first_nm), '[]'::jsonb)
    INTO v_people$a$;
  v_new_cte text := $a$  ),
  pact AS (
    -- The frozen paycheck for this week, if payroll has transmitted. One row per
    -- person; its presence is what flips a row from computed to actual.
    SELECT pd.team_member_id,
           COALESCE((pd.raw_earnings->'items'->'SALARY'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'HOURLY'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'PTO'->>'period')::numeric, 0)
         + COALESCE((pd.raw_earnings->'items'->'- O/TIME'->>'period')::numeric, 0) AS pay,
           COALESCE((pd.raw_earnings->'items'->'1Comm'->>'period')::numeric, 0)   AS c1,
           COALESCE((pd.raw_earnings->'items'->'2Team'->>'period')::numeric, 0)   AS c2,
           COALESCE((pd.raw_earnings->'items'->'3Market'->>'period')::numeric, 0) AS c3,
           COALESCE((pd.raw_earnings->'items'->'4Goals'->>'period')::numeric, 0)  AS c4,
           COALESCE((pd.raw_earnings->'items'->'5Manage'->>'period')::numeric, 0) AS c5,
           COALESCE((pd.raw_earnings->'items'->'LIFE *'->>'period')::numeric, 0)  AS add_in
    FROM public.payroll_detail pd
    JOIN public.payroll_runs pr ON pr.id = pd.payroll_run_id
    WHERE pd.agency_id = p_agency_id
      AND pr.pay_period_end = v_week_end
  )
  SELECT COALESCE(jsonb_agg(x ORDER BY pay_ord, last_nm, first_nm), '[]'::jsonb)
    INTO v_people$a$;

  v_old_pay text := $b$      'pay',                 w.pay,
      'codes', jsonb_build_object(
        '1Comm',   COALESCE(bon.c1, 0),
        '2Team',   COALESCE(bon.c2, 0),
        '3Market', COALESCE(bon.c3, 0),
        '4Goals',  COALESCE(bon.c4, 0),
        '5Manage', COALESCE(bon.c5, 0)
      ),$b$;
  v_new_pay text := $b$      'pay',                 z.pay,
      'from_payroll',        z.from_payroll,
      'codes', jsonb_build_object(
        '1Comm',   z.c1,
        '2Team',   z.c2,
        '3Market', z.c3,
        '4Goals',  z.c4,
        '5Manage', z.c5
      ),$b$;

  v_old_bd text := $c$      'before_deductions', ROUND(COALESCE(w.pay, 0) + z.bonus_total + z.add_in, 2),$c$;
  v_new_bd text := $c$      'before_deductions', ROUND(COALESCE(z.pay, 0) + z.bonus_total + z.add_in, 2),$c$;

  v_old_join text := $d$    LEFT JOIN lns  ON lns.team_member_id  = t.id$d$;
  v_new_join text := $d$    LEFT JOIN lns  ON lns.team_member_id  = t.id
    LEFT JOIN pact ON pact.team_member_id = t.id$d$;

  v_old_z text := $e$    CROSS JOIN LATERAL (
      SELECT COALESCE(bon.c1, 0) + COALESCE(bon.c2, 0) + COALESCE(bon.c3, 0)
           + COALESCE(bon.c4, 0) + COALESCE(bon.c5, 0) AS bonus_total,
             COALESCE(lns.add_in, 0)   AS add_in,
             COALESCE(lns.take_out, 0) AS take_out
    ) z$e$;
  v_new_z text := $e$    CROSS JOIN LATERAL (
      -- Paycheck wins wherever there is one. No payroll row for the week means
      -- every figure stays the computed one, exactly as before.
      SELECT (pact.team_member_id IS NOT NULL) AS from_payroll,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.pay    ELSE w.pay                  END AS pay,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c1     ELSE COALESCE(bon.c1, 0)    END AS c1,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c2     ELSE COALESCE(bon.c2, 0)    END AS c2,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c3     ELSE COALESCE(bon.c3, 0)    END AS c3,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c4     ELSE COALESCE(bon.c4, 0)    END AS c4,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.c5     ELSE COALESCE(bon.c5, 0)    END AS c5,
             CASE WHEN pact.team_member_id IS NOT NULL THEN pact.add_in ELSE COALESCE(lns.add_in, 0) END AS add_in,
             COALESCE(lns.take_out, 0) AS take_out
    ) z0
    CROSS JOIN LATERAL (
      SELECT z0.from_payroll, z0.pay, z0.c1, z0.c2, z0.c3, z0.c4, z0.c5,
             z0.add_in, z0.take_out,
             ROUND(z0.c1 + z0.c2 + z0.c3 + z0.c4 + z0.c5, 2) AS bonus_total
    ) z$e$;

  v_old_ret text := $f$    'has_cpr_report',   v_report_id IS NOT NULL,$f$;
  v_new_ret text := $f$    'has_cpr_report',   v_report_id IS NOT NULL,
    'payroll_received', EXISTS (
      SELECT 1 FROM public.payroll_runs pr
      WHERE pr.pay_period_end = v_week_end
        AND EXISTS (SELECT 1 FROM public.payroll_detail pd
                    WHERE pd.payroll_run_id = pr.id AND pd.agency_id = p_agency_id)
    ),$f$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'team_payroll_week';

  IF v_def IS NULL                    THEN RAISE EXCEPTION 'team_payroll_week not found'; END IF;
  IF position(v_old_cte  in v_def) = 0 THEN RAISE EXCEPTION 'CTE tail did not match';      END IF;
  IF position(v_old_pay  in v_def) = 0 THEN RAISE EXCEPTION 'pay/codes block did not match'; END IF;
  IF position(v_old_bd   in v_def) = 0 THEN RAISE EXCEPTION 'before_deductions did not match'; END IF;
  IF position(v_old_join in v_def) = 0 THEN RAISE EXCEPTION 'lns join did not match';      END IF;
  IF position(v_old_z    in v_def) = 0 THEN RAISE EXCEPTION 'z lateral did not match';     END IF;
  IF position(v_old_ret  in v_def) = 0 THEN RAISE EXCEPTION 'return block did not match';  END IF;

  v_def := replace(v_def, v_old_cte,  v_new_cte);
  v_def := replace(v_def, v_old_pay,  v_new_pay);
  v_def := replace(v_def, v_old_bd,   v_new_bd);
  v_def := replace(v_def, v_old_join, v_new_join);
  v_def := replace(v_def, v_old_z,    v_new_z);
  v_def := replace(v_def, v_old_ret,  v_new_ret);

  EXECUTE v_def;
END
$mig$;
