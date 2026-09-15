-- Peter ruling 2026-09-14: a record that was deleted must not count in sales points,
-- and neither must one that was charged back, even partially.
--
-- Two places carry the ruling.
--
-- 1) rp_scale_points_by_prior counted prior rows where status <> 'voided', but the
--    delete functions write 'void'. Removed rows were still lifting the ladder.
--    Cover both spellings.
CREATE OR REPLACE FUNCTION public.rp_scale_points_by_prior()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_pct numeric; v_cap integer; v_prior integer; v_start date;
BEGIN
  IF NEW.points IS NULL OR NEW.points <= 0 THEN RETURN NEW; END IF;
  SELECT COALESCE(v.prior_step_pct, 0), COALESCE(v.prior_cap, 0) INTO v_pct, v_cap
  FROM public.retention_point_values v WHERE v.agency_id = NEW.agency_id AND v.activity_key = NEW.activity_key;
  IF NOT FOUND OR v_pct <= 0 OR v_cap <= 0 THEN RETURN NEW; END IF;
  SELECT c.cycle_start INTO v_start FROM public.current_cycle_info(NEW.agency_id, NEW.occurred_on) c;
  v_start := COALESCE(v_start, date_trunc('quarter', NEW.occurred_on)::date);
  SELECT count(*) INTO v_prior FROM public.retention_activity_log p
  WHERE p.agency_id = NEW.agency_id AND p.team_member_id = NEW.team_member_id AND p.activity_key = NEW.activity_key
    -- both spellings: the void functions write 'void', older rows carry 'voided'
    AND p.status NOT IN ('void', 'voided') AND p.points > 0
    AND p.occurred_on >= v_start AND p.occurred_on <= NEW.occurred_on;
  NEW.points := ROUND(NEW.points * (1 + (v_pct / 100.0) * LEAST(v_cap, v_prior)), 2);
  RETURN NEW;
END $function$;

-- 2) rp_week_scoreboard_for is the ONLY function that feeds compute_sp_from_production.
--    Its prod CTE already drops sales whose status is not active. It must also drop any
--    sold-policy row that has an active cancelation matched to it, because a partial
--    chargeback still means the policy is out. Surgical replace so every other line of a
--    17 kB function stays exactly as it is.
DO $migrate$
DECLARE v_def text; v_new text; v_old_anchor text; v_new_anchor text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';
  IF v_def IS NULL THEN RAISE EXCEPTION 'rp_week_scoreboard_for not found'; END IF;

  v_old_anchor :=
    E'    WHERE s.agency_id = p_agency_id AND s.status = ''active'' AND p.issued_date IS NOT NULL\n'
 || E'      AND p.issued_date BETWEEN v_cycle_start AND v_week_end\n'
 || E'  ),\n  sp AS (';

  v_new_anchor :=
    E'    WHERE s.agency_id = p_agency_id AND s.status = ''active'' AND p.issued_date IS NOT NULL\n'
 || E'      AND p.issued_date BETWEEN v_cycle_start AND v_week_end\n'
 || E'      -- Peter 2026-09-14: charged back, even partially, means out of sales points.\n'
 || E'      AND NOT EXISTS (SELECT 1 FROM public.cancelation_log cb\n'
 || E'                       WHERE cb.matched_sale_product_id = p.id AND cb.status = ''active'')\n'
 || E'  ),\n  sp AS (';

  IF position(v_old_anchor in v_def) = 0 THEN
    RAISE EXCEPTION 'prod CTE anchor not found - rp_week_scoreboard_for has changed, re-read it before patching';
  END IF;

  v_new := replace(v_def, v_old_anchor, v_new_anchor);
  IF v_new = v_def THEN RAISE EXCEPTION 'replacement made no change'; END IF;
  EXECUTE v_new;
END $migrate$;
