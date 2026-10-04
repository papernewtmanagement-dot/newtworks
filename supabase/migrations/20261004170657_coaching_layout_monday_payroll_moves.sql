DO $do$
DECLARE d text; n text; a int; b int;
BEGIN
  d := pg_get_functiondef('public.onboarding_coaching_week_layout(uuid,integer,date,date,date,text[])'::regprocedure);
  a := position('    v_pay_hard := false;' in d);
  b := position('    v_changes := v_changes || v_day_changes;' in d);
  IF a = 0 OR b = 0 THEN RAISE EXCEPTION 'anchors'; END IF;
  n := left(d, a - 1) || $x$    v_fit := public.onboarding_coaching_fit(public.calendar_open_stretches(v_ws, v_we, v_hard), v_queue);
    v_day_changes := '[]'::jsonb; v_mv := NULL; v_pay_cancel := false;
    IF v_pay IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_fit->'placed') p
         WHERE (p->>'s')::timestamptz < (v_pay->>'end')::timestamptz AND (p->>'e')::timestamptz > (v_pay->>'start')::timestamptz) THEN
      v_dur := (v_pay->>'end')::timestamptz - (v_pay->>'start')::timestamptz;
      IF extract(isodow FROM v_days[v_i]) <> 1 THEN
        -- Tue-Fri: the earliest later time the coaching leaves open (not on a kept Admin block), else canceled
        v_keep_admin := v_adm IS NULL OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_fit->'placed') p
             WHERE (p->>'s')::timestamptz < (v_adm->>'end')::timestamptz AND (p->>'e')::timestamptz > (v_adm->>'start')::timestamptz);
        v_placed_busy := COALESCE((SELECT jsonb_agg(jsonb_build_object('s', p->'s', 'e', p->'e')) FROM jsonb_array_elements(v_fit->'placed') p), '[]'::jsonb);
        v_open := public.calendar_open_stretches(v_ws, v_we, v_hard || v_placed_busy ||
                    CASE WHEN v_keep_admin AND v_adm IS NOT NULL THEN jsonb_build_array(jsonb_build_object('s', v_adm->'start', 'e', v_adm->'end')) ELSE '[]'::jsonb END);
        SELECT GREATEST((o->>'s')::timestamptz, (v_pay->>'start')::timestamptz) INTO v_mv FROM jsonb_array_elements(v_open) o
         WHERE (o->>'e')::timestamptz - GREATEST((o->>'s')::timestamptz, (v_pay->>'start')::timestamptz) >= v_dur ORDER BY 1 LIMIT 1;
        v_pay_cancel := v_mv IS NULL;
      ELSE
        -- Monday: move only. Try staying put and each later open time (latest first); keep whichever leaves the most
        -- coaching that day, preferring a move on a tie. Never onto a kept Admin block.
        v_best := public.onboarding_coaching_fit(public.calendar_open_stretches(v_ws, v_we, v_hard ||
                    jsonb_build_array(jsonb_build_object('s', v_pay->'start', 'e', v_pay->'end'))), v_queue);
        v_best_m := (SELECT COALESCE(sum(extract(epoch FROM (p->>'e')::timestamptz - (p->>'s')::timestamptz) / 60), 0) FROM jsonb_array_elements(v_best->'placed') p);
        FOR v_cand IN SELECT (o->>'e')::timestamptz - v_dur AS cs FROM jsonb_array_elements(public.calendar_open_stretches(v_ws, v_we, v_hard)) o
                       WHERE (o->>'e')::timestamptz - v_dur > (v_pay->>'start')::timestamptz
                         AND (o->>'e')::timestamptz - v_dur >= (o->>'s')::timestamptz ORDER BY 1 DESC LOOP
          v_try := public.onboarding_coaching_fit(public.calendar_open_stretches(v_ws, v_we, v_hard ||
                     jsonb_build_array(jsonb_build_object('s', v_cand.cs, 'e', v_cand.cs + v_dur))), v_queue);
          CONTINUE WHEN v_adm IS NOT NULL AND v_cand.cs < (v_adm->>'end')::timestamptz AND v_cand.cs + v_dur > (v_adm->>'start')::timestamptz
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_try->'placed') p
                 WHERE (p->>'s')::timestamptz < (v_adm->>'end')::timestamptz AND (p->>'e')::timestamptz > (v_adm->>'start')::timestamptz);
          v_m := (SELECT COALESCE(sum(extract(epoch FROM (p->>'e')::timestamptz - (p->>'s')::timestamptz) / 60), 0) FROM jsonb_array_elements(v_try->'placed') p);
          IF v_m > v_best_m OR (v_m = v_best_m AND v_mv IS NULL) THEN v_best := v_try; v_best_m := v_m; v_mv := v_cand.cs; END IF;
        END LOOP;
        v_fit := v_best;
      END IF;
    END IF;
    IF v_adm IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_fit->'placed') p
         WHERE (p->>'s')::timestamptz < (v_adm->>'end')::timestamptz AND (p->>'e')::timestamptz > (v_adm->>'start')::timestamptz) THEN
      v_day_changes := v_day_changes || jsonb_build_object('kind', 'Admin', 'action', 'cancel', 'event_id', v_adm->>'id',
                         'date', v_days[v_i], 'start', v_adm->'start', 'end', v_adm->'end');
    END IF;
    IF v_mv IS NOT NULL THEN
      v_day_changes := v_day_changes || jsonb_build_object('kind', 'Payroll', 'action', 'move', 'event_id', v_pay->>'id',
                         'date', v_days[v_i], 'start', v_mv, 'end', v_mv + v_dur);
    ELSIF v_pay_cancel THEN
      v_day_changes := v_day_changes || jsonb_build_object('kind', 'Payroll', 'action', 'cancel', 'event_id', v_pay->>'id',
                         'date', v_days[v_i], 'start', v_pay->'start', 'end', v_pay->'end');
    END IF;
$x$ || substr(d, b);
  n := replace(n, $x$v_lines text[]; v_placed_busy jsonb;$x$, $x$v_lines text[]; v_placed_busy jsonb;
  v_pay_cancel boolean; v_best jsonb; v_best_m numeric; v_try jsonb; v_m numeric; v_cand record;$x$);
  EXECUTE n;
END $do$;
