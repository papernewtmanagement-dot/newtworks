-- Assessment invite copy: measured sitting length; quad48 norm rebuild threshold per the record.
--
-- 1. send_v1_assessment_invitations said "about 30 minutes" twice. Measured on the 27 completed
--    v2fcq sittings (per-item time capped at 3 minutes, so pauses do not count): stint 1 median
--    15.8 min, ranking blocks median 36 s each x 48 = 28.8 min, written items median 8.5 min,
--    whole sitting median 58.6 min (75th percentile 72.6). The invite now says "about an hour"
--    (cut plan 2026-09-10: "fix the invite copy ... to the measured number"). The body is patched
--    in place (read, assert one match each, rewrite), nothing retyped.
-- 2. hiregauge_fcq_block_sets.quad48.norm_rebuild_min_n: 26 -> 20. The approved cut plan says
--    "rebuild at N>=20 on the new set"; 26 was the count the 2026-09-10 manual rebuild happened
--    to run at, not a decision. Verdict bands (44/58) are re-anchored when that rebuild lands.

DO $$
DECLARE
  v_def text;
  v_old text;
  v_n int;
BEGIN
  v_def := pg_get_functiondef('public.send_v1_assessment_invitations'::regproc);

  v_old := 'It takes about 30 minutes';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'send_v1_assessment_invitations: expected 1 match for "%", found %', v_old, v_n; END IF;
  v_def := replace(v_def, v_old, 'It takes about an hour');

  v_old := 'please take about 30 minutes to complete it';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'send_v1_assessment_invitations: expected 1 match for "%", found %', v_old, v_n; END IF;
  v_def := replace(v_def, v_old, 'please take about an hour to complete it');

  IF position('AS $function$' || E'\n' IN v_def) = 0 THEN RAISE EXCEPTION 'send_v1_assessment_invitations: body marker not found'; END IF;
  v_def := replace(v_def, 'AS $function$' || E'\n',
    'AS $function$' || E'\n' || '  -- 2026-09-11: sitting length wording is the measured median (about an hour); see migration invite_copy_measured_hour_and_fcq_min_n_20.' || E'\n');
  EXECUTE v_def;

  IF pg_get_functiondef('public.send_v1_assessment_invitations'::regproc) LIKE '%about 30 minutes%' THEN
    RAISE EXCEPTION 'send_v1_assessment_invitations still says about 30 minutes';
  END IF;
END $$;

UPDATE public.hiregauge_fcq_block_sets
SET norm_rebuild_min_n = 20, updated_at = now(),
    notes = replace(notes, 'auto-rebuilt at N>=26 completed sittings on this set', 'auto-rebuilt at N>=20 completed sittings on this set (cut plan 2026-09-10)')
WHERE set_key = 'quad48';

UPDATE public.hiregauge_facet_norms
SET notes = replace(notes, 'Auto-rebuild at N>=26 (trg_fcq_norm_auto_rebuild)', 'Auto-rebuild at N>=20 (trg_fcq_norm_auto_rebuild)'),
    retrieved_from = replace(retrieved_from, 'at N>=26 completed sittings on quad48', 'at N>=20 completed sittings on quad48')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND updated_by = 'claude_migration_fc_quad_flip_16traits';

DO $$
DECLARE v_min int; v_notes int;
BEGIN
  SELECT norm_rebuild_min_n INTO v_min FROM public.hiregauge_fcq_block_sets WHERE set_key = 'quad48';
  SELECT count(*) INTO v_notes FROM public.hiregauge_facet_norms
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND notes LIKE '%Auto-rebuild at N>=20 (trg_fcq_norm_auto_rebuild)%';
  IF v_min <> 20 OR v_notes <> 16 THEN
    RAISE EXCEPTION 'threshold update wrong: min_n=%, % seed rows relabelled', v_min, v_notes;
  END IF;
END $$;
