-- TASK 3 (build-instructions 2026-08-06): drift detector for
-- COMPETENCY_FACET_INPUTS in generate-custom-probes/index.ts.
--
-- That JS object is a hand copy of the facet inputs used by the 12
-- newtworks_competency_* facet-based functions (newtworks_competency_gma is
-- the 13th and reads GMA, not a facet, so it's correctly excluded).
-- Confirmed 2026-08-06 by checking gma's actual body: it only reads
-- gma_total, no personality facet. If any of the 12 functions' facet inputs
-- ever change, this table + this function catch it. The JS copy itself
-- can't be read from SQL, so this compares against a canonical snapshot
-- seeded here -- keeping that snapshot in sync with the JS is the same
-- "edit both" discipline the operational_rule already requires; this adds
-- a monthly check that actually notices if someone forgets.

CREATE TABLE IF NOT EXISTS public.hiregauge_competency_facet_canonical (
  competency_name text PRIMARY KEY,
  facets text[] NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  source_note text
);

INSERT INTO public.hiregauge_competency_facet_canonical (competency_name, facets, source_note) VALUES
  ('drive_work_intensity',           ARRAY['achievement_striving','self_discipline','proactive_personality'], 'verified against live pg_proc 2026-08-06 -- corrected a phantom "enterprising" entry same day'),
  ('persuasive_influence',           ARRAY['assertiveness','political_skill_networking','self_efficacy'], 'verified against live pg_proc 2026-08-06 -- corrected a phantom "enterprising" entry same day'),
  ('rapport_building',               ARRAY['friendliness','political_skill_networking','compassion','trust'], 'verified against live pg_proc 2026-08-06'),
  ('needs_discovery',                ARRAY['customer_orientation','compassion','cooperation'], 'verified against live pg_proc 2026-08-06 -- gma_total excluded, not a facet'),
  ('resilience_under_rejection',     ARRAY['emotional_stability','anxiety','dispositional_optimism','self_efficacy'], 'verified against live pg_proc 2026-08-06 -- anxiety_reversed normalized to anxiety'),
  ('composure_under_pressure',       ARRAY['anger','anxiety','emotional_stability'], 'verified against live pg_proc 2026-08-06 -- anger_reversed/anxiety_reversed normalized; sjt_composure_under_load excluded'),
  ('accuracy_procedural_discipline', ARRAY['dutifulness','cautiousness','self_discipline'], 'verified against live pg_proc 2026-08-06 -- gma_total excluded'),
  ('rule_compliance_adherence',      ARRAY['dutifulness','cautiousness'], 'verified against live pg_proc 2026-08-06 -- sjt_compliance_* excluded'),
  ('integrity',                      ARRAY['sincerity','fairness','greed_avoidance'], 'verified against live pg_proc 2026-08-06 -- sjt_honesty_integrity excluded'),
  ('judgment_escalation',            ARRAY['cautiousness','dutifulness'], 'verified against live pg_proc 2026-08-06 -- sjt_escalation_judgment, gma_total excluded'),
  ('coachability_team_contribution', ARRAY['cooperation','trust','compassion','anger'], 'verified against live pg_proc 2026-08-06 -- anger_reversed normalized'),
  ('autonomy_ownership',             ARRAY['proactive_personality','self_efficacy','achievement_striving'], 'verified against live pg_proc 2026-08-06 -- corrected a phantom "enterprising" entry same day')
ON CONFLICT (competency_name) DO UPDATE SET facets = EXCLUDED.facets, source_note = EXCLUDED.source_note, updated_at = now();

CREATE OR REPLACE FUNCTION public.hiregauge_detect_facet_input_drift()
RETURNS TABLE(competency_name text, canonical_facets text[], live_facets text[], drifted boolean)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_row RECORD;
  v_def text;
  v_labels_block text;
  v_live text[];
  v_canonical text[];
  v_alert_exists boolean;
BEGIN
  FOR v_row IN
    SELECT c.competency_name, c.facets AS canon, p.oid
    FROM public.hiregauge_competency_facet_canonical c
    JOIN pg_proc p
      ON p.proname = 'newtworks_competency_' || c.competency_name
     AND p.pronamespace = 'public'::regnamespace
  LOOP
    v_def := pg_get_functiondef(v_row.oid);

    -- The labels ARRAY[...] block is the one that does NOT contain
    -- '::numeric' (that marks the OTHER array -- the numeric values).
    SELECT string_agg(m[1], ',') INTO v_labels_block
    FROM regexp_matches(v_def, 'ARRAY\[([^\]]*)\]', 'g') AS t(m)
    WHERE m[1] NOT ILIKE '%::numeric%';

    SELECT array_agg(DISTINCT regexp_replace(x, '_reversed$', ''))
      INTO v_live
    FROM regexp_matches(COALESCE(v_labels_block, ''), '''([a-z_]+)''', 'g') AS t(g),
         LATERAL (SELECT g[1] AS x) s
    WHERE x <> 'gma_total' AND x NOT LIKE 'sjt\_%' ESCAPE '\';

    v_canonical := (SELECT array_agg(f ORDER BY f) FROM unnest(v_row.canon) f);
    v_live       := (SELECT array_agg(f ORDER BY f) FROM unnest(COALESCE(v_live, ARRAY[]::text[])) f);

    competency_name  := v_row.competency_name;
    canonical_facets := v_canonical;
    live_facets       := v_live;
    drifted            := (v_canonical IS DISTINCT FROM v_live);
    RETURN NEXT;

    IF drifted THEN
      SELECT EXISTS(
        SELECT 1 FROM public.alerts
        WHERE module_reference = 'generate-custom-probes:competency_facet_drift:' || v_row.competency_name
          AND is_resolved = false
      ) INTO v_alert_exists;

      IF NOT v_alert_exists THEN
        INSERT INTO public.alerts (id, agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, created_at)
        VALUES (
          gen_random_uuid(),
          '126794dd-25ff-47d2-a436-724499733365',
          'competency_facet_drift',
          'warning',
          format('Facet inputs drifted for competency "%s"', v_row.competency_name),
          format('COMPETENCY_FACET_INPUTS in generate-custom-probes/index.ts has %s for "%s", but the live SQL function newtworks_competency_%s now reads %s. Update the JS mapping, redeploy generate-custom-probes, and update hiregauge_competency_facet_canonical to match.',
                 v_canonical::text, v_row.competency_name, v_row.competency_name, v_live::text),
          'generate-custom-probes:competency_facet_drift:' || v_row.competency_name,
          false, false, now()
        );
      END IF;
    END IF;
  END LOOP;
  RETURN;
END;
$function$;

COMMENT ON FUNCTION public.hiregauge_detect_facet_input_drift() IS
'Monthly check (see pg_cron schedule) comparing hiregauge_competency_facet_canonical (a DB snapshot of what generate-custom-probes/index.ts COMPETENCY_FACET_INPUTS SHOULD contain) against what the live newtworks_competency_* SQL functions actually use. Divergence -> alerts row (idempotent per competency). Both the JS object and this canonical table must be updated together whenever a competency facet function is recalibrated -- this function only catches the case where someone forgets.';
