-- Peter 2026-09-27: anyone whose net quotes come out below zero after requirements
-- must buy back to zero at $10/quote, every week, no matter what else is happening
-- (team winning or not, licensed or not, personal minimum met or not).
-- Starts with the week ending 2026-09-26. The existing personal-minimum buy-back
-- (15 Sales / 8 Retention, team on track to win) is unchanged; a person gets the larger of the two.
DO $mig$
DECLARE
  d  text;
  d2 text;
  a1 text := E'  IF v_eligible THEN\n    WITH personal AS (';
  b1 text := E'    WITH personal AS (';
  a2 text := E'        CASE\n          WHEN p.personal_min IS NOT NULL';
  b2 text := E'        GREATEST(CASE\n          WHEN v_eligible AND p.personal_min IS NOT NULL';
  a3 text := E'          ELSE 0\n        END AS buyback';
  b3 text := E'          ELSE 0\n        END,\n        -- Peter 2026-09-27: net below zero always buys back to zero, from week ending 2026-09-26\n        CASE WHEN p_week_ending_date >= DATE ''2026-09-26'' AND (cs.v->>''net_quotes'')::numeric < 0\n             THEN CEIL(-(cs.v->>''net_quotes'')::numeric)::int ELSE 0 END) AS buyback';
  a4 text := E'  ELSE\n    SELECT jsonb_object_agg((key)::text, value || jsonb_build_object(''buyback'', 0))\n    INTO v_state\n    FROM jsonb_each(v_state);\n  END IF;';
  b4 text := '';
BEGIN
  d := pg_get_functiondef('public.get_weekly_cpr_requirements(uuid,date)'::regprocedure);
  IF (length(d)-length(replace(d,a1,'')))/length(a1) <> 1 THEN RAISE EXCEPTION 'anchor a1'; END IF;
  IF (length(d)-length(replace(d,a2,'')))/length(a2) <> 1 THEN RAISE EXCEPTION 'anchor a2'; END IF;
  IF (length(d)-length(replace(d,a3,'')))/length(a3) <> 1 THEN RAISE EXCEPTION 'anchor a3'; END IF;
  IF (length(d)-length(replace(d,a4,'')))/length(a4) <> 1 THEN RAISE EXCEPTION 'anchor a4'; END IF;
  d2 := replace(replace(replace(replace(d, a1, b1), a2, b2), a3, b3), a4, b4);
  EXECUTE d2;
END
$mig$;
