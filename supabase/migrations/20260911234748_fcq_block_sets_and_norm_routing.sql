-- Phase 4 forced-choice personality: block-set registry + set-aware norm routing (2026-09-11).
--
-- WHY: the 75-block set (items 701-775, 25 facets) is being replaced by a 48-block set
--   (items 776-823, 16 facets; migration 20260911220312, still inactive). A local norm
--   describes ONE block set (Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014), so
--   candidates who answered the old blocks must keep percentiling against the old norms
--   after the flip, while new candidates get norms built on the new blocks. Same pattern
--   the GMA section uses (migrations gma_norm_rebuild_per_item_set 20260903010526 and
--   role_fit_v5_9_gma_item_set_norms 20260903010704): a set registry, each candidate locked
--   to a set, the current set reading the plain 'fcq_<facet>' rows and a retired set reading
--   its frozen 'fcq_<facet>@<set>' rows.
--
-- WHAT (additive; every candidate's numbers are unchanged, and the migration proves it):
--   1. hiregauge_fcq_block_sets + hiregauge_fcq_block_set_members: quad75 (current, norms
--      rebuilt at N=26 on 2026-09-10) and quad48 (not active yet, provisional).
--   2. hiring_candidates.fcq_block_set: locked at finalize (BEFORE UPDATE OF
--      assessment_source), inferred from the answered blocks; backfilled now for every
--      candidate with any block answered (all quad75).
--   3. Frozen copies: fcq_<facet>@quad75 for the 25 current rows, values identical. Unused
--      until quad75 is retired (the flip migration), then read by quad75 candidates.
--   4. hiregauge_facet_norm_key(source, set, facet): plain row for the current set,
--      '<row>@<set>' for a retired set. The 2-arg form keeps its meaning (current set).
--      The four consumers (_assessment_character_parts, assessment_commitment,
--      hiregauge_candidate_facet_percentiles, _newtworks_role_fit_core) are patched in
--      place to pass the candidate's fcq_block_set: the migration reads each body with
--      pg_get_functiondef, asserts the exact number of call sites, rewrites them and
--      re-creates the function. Nothing is retyped, so nothing can drift.
--   5. hiregauge_fcq_norm_rebuild_current_set(agency, force): rebuilds the current set's
--      plain rows once N >= norm_rebuild_min_n completed, reliable, non-test sittings on
--      that set exist. Same population rule that produced the 2026-09-10 numbers
--      (reproduced exactly before this was written). Fired by a trigger at finalize, never
--      blocks a candidate write, alerts on success or failure.
--   6. Self-check: every v2fcq candidate's percentiles, three construct scores, composite
--      and verdict are snapshotted before any change and compared after all of it. Any
--      difference raises and rolls the whole migration back.
--
-- NOT here: quad75 stays current, items 701-775 stay active, 776-823 stay inactive, no norm
--   value changes. The flip (retire quad75 -> frozen, activate quad48, seed the 16 plain
--   rows) is the next migration.

-- ---------------------------------------------------------------------------
-- 0. Snapshot before anything changes (temp, same transaction).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE fcq_step4_before AS
SELECT c.id,
       v.capability_score, v.character_score, v.commitment_score, v.composite, v.verdict,
       (SELECT jsonb_object_agg(p.facet, p.percentile)
          FROM public.hiregauge_candidate_facet_percentiles(c.id) p) AS pct
FROM public.hiring_candidates c
CROSS JOIN LATERAL public.verdict_assessment(c.id, NULL) v
WHERE c.assessment_source = 'v2fcq';

-- ---------------------------------------------------------------------------
-- 1. Registry
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hiregauge_fcq_block_sets (
  set_key            text PRIMARY KEY,
  agency_id          uuid NOT NULL,
  label              text NOT NULL,
  is_current         boolean NOT NULL DEFAULT false,
  activated_at       timestamptz,
  retired_at         timestamptz,
  norm_status        text NOT NULL DEFAULT 'provisional_seed'
                     CHECK (norm_status IN ('provisional_seed', 'rebuilt', 'frozen')),
  norm_rebuild_min_n integer NOT NULL DEFAULT 26,
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS hiregauge_fcq_block_sets_one_current
  ON public.hiregauge_fcq_block_sets (agency_id) WHERE is_current;

CREATE TABLE IF NOT EXISTS public.hiregauge_fcq_block_set_members (
  set_key text NOT NULL REFERENCES public.hiregauge_fcq_block_sets(set_key),
  item_id uuid NOT NULL REFERENCES public.hiregauge_instrument_items(id),
  PRIMARY KEY (set_key, item_id)
);

ALTER TABLE public.hiregauge_fcq_block_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hiregauge_fcq_block_set_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS authenticated_select_hiregauge_fcq_block_sets ON public.hiregauge_fcq_block_sets;
CREATE POLICY authenticated_select_hiregauge_fcq_block_sets
  ON public.hiregauge_fcq_block_sets FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS authenticated_select_hiregauge_fcq_block_set_members ON public.hiregauge_fcq_block_set_members;
CREATE POLICY authenticated_select_hiregauge_fcq_block_set_members
  ON public.hiregauge_fcq_block_set_members FOR SELECT TO authenticated USING (true);

INSERT INTO public.hiregauge_fcq_block_sets
  (set_key, agency_id, label, is_current, activated_at, retired_at, norm_status, norm_rebuild_min_n, notes)
VALUES
  ('quad75', '126794dd-25ff-47d2-a436-724499733365',
   '75 ranking blocks, 25 facets (items 701-775), live 2026-08-25',
   true, '2026-08-25 19:40:01+00', NULL, 'rebuilt', 26,
   'Assembly of record: persistent_memory spec c310fba8-cf15-4818-817a-d0a56f2f4719 (migration fc_quad_blocks_75_inactive). Norms: 2026-08-25 provisional 50/13 seed, rebuilt 2026-09-10 from 26 completed sittings (migration fcq_facet_norms_rebuild_n26). Refresh at N>=50 by hand (p_force). To be retired by the 16-trait flip; norms then frozen as fcq_<facet>@quad75.'),
  ('quad48', '126794dd-25ff-47d2-a436-724499733365',
   '48 ranking blocks, 16 facets (items 776-823), 2026-09-11 rebuild',
   false, NULL, NULL, 'provisional_seed', 26,
   'Assembly of record: persistent_memory spec de57d141-0906-46c7-b077-b8f6e853a41e (migration fc_quad_blocks_48_16traits_inactive). Same 192 statements as quad75 for the 16 kept facets; dropped sincerity, fairness, greed_avoidance, anxiety, anger, trust, competitiveness, prove_goal_orientation, avoid_goal_orientation (Peter 2026-09-10). Not active until the flip migration; plain fcq_<facet> rows are seeded there and auto-rebuilt at N>=26 completed sittings on this set.')
ON CONFLICT (set_key) DO NOTHING;

INSERT INTO public.hiregauge_fcq_block_set_members (set_key, item_id)
SELECT CASE WHEN i.item_number BETWEEN 701 AND 775 THEN 'quad75' ELSE 'quad48' END, i.id
FROM public.hiregauge_instrument_items i
WHERE i.section = 'newtworks_v2_personality_fc_quad'
  AND i.item_number BETWEEN 701 AND 823
ON CONFLICT DO NOTHING;

DO $$
DECLARE v_75 int; v_48 int;
BEGIN
  SELECT count(*) INTO v_75 FROM public.hiregauge_fcq_block_set_members WHERE set_key = 'quad75';
  SELECT count(*) INTO v_48 FROM public.hiregauge_fcq_block_set_members WHERE set_key = 'quad48';
  IF v_75 <> 75 OR v_48 <> 48 THEN
    RAISE EXCEPTION 'block set membership wrong: quad75=% quad48=%', v_75, v_48;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Candidate lock column
-- ---------------------------------------------------------------------------
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS fcq_block_set text REFERENCES public.hiregauge_fcq_block_sets(set_key);
COMMENT ON COLUMN public.hiring_candidates.fcq_block_set IS
  'Ranking-block set (hiregauge_fcq_block_sets) this candidate answered at stint 2. Locked at finalize by trg_fcq_lock_block_set from the answered items; decides which fcq_<facet> norm rows their percentiles use (hiregauge_facet_norm_key 3-arg form).';

-- ---------------------------------------------------------------------------
-- 3. Set helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_fcq_current_set(p_agency uuid)
RETURNS text
LANGUAGE sql
STABLE
AS $function$
  SELECT set_key FROM public.hiregauge_fcq_block_sets
  WHERE agency_id = p_agency AND is_current
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_fcq_candidate_set(p_candidate_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $function$
-- The ranking-block set a candidate is on. Order of authority (mirrors
-- hiregauge_gma_candidate_set):
--   1. hiring_candidates.fcq_block_set (locked at finalize);
--   2. the set that contains EVERY stint-2 ranking block they have answered at
--      sitting 1, preferring a retired set (a candidate who answered a retired
--      block never reads as current);
--   3. the current set (nothing answered yet).
DECLARE
  v_agency uuid;
  v_locked text;
  v_inferred text;
BEGIN
  SELECT agency_id, fcq_block_set INTO v_agency, v_locked
  FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency IS NULL THEN RETURN NULL; END IF;
  IF v_locked IS NOT NULL THEN RETURN v_locked; END IF;

  SELECT m.set_key INTO v_inferred
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  JOIN public.hiregauge_fcq_block_set_members m ON m.item_id = r.item_id
  JOIN public.hiregauge_fcq_block_sets s ON s.set_key = m.set_key
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = 1
    AND i.section = 'newtworks_v2_personality_fc_quad'
  GROUP BY m.set_key, s.is_current, s.activated_at
  HAVING count(*) = (
    SELECT count(*) FROM public.hiregauge_candidate_responses r2
    JOIN public.hiregauge_instrument_items i2 ON i2.id = r2.item_id
    WHERE r2.candidate_id = p_candidate_id
      AND r2.sitting = 1
      AND i2.section = 'newtworks_v2_personality_fc_quad'
  )
  ORDER BY s.is_current ASC, s.activated_at DESC NULLS LAST
  LIMIT 1;

  RETURN COALESCE(v_inferred, public.hiregauge_fcq_current_set(v_agency));
END;
$function$;

-- Set-aware norm key. The 2-arg hiregauge_facet_norm_key(source, facet) is unchanged
-- and still means "the current set". This form adds the candidate's set: a retired
-- set reads its frozen 'fcq_<facet>@<set>' rows. gma / sjt / gma_speed are never
-- prefixed (same rule as the 2-arg form).
CREATE OR REPLACE FUNCTION public.hiregauge_facet_norm_key(p_source text, p_set text, p_facet text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_base text;
  v_current boolean;
BEGIN
  v_base := public.hiregauge_facet_norm_key(p_source, p_facet);
  IF p_source IS DISTINCT FROM 'v2fcq' OR p_set IS NULL OR v_base = p_facet THEN
    RETURN v_base;
  END IF;
  SELECT is_current INTO v_current FROM public.hiregauge_fcq_block_sets WHERE set_key = p_set;
  IF v_current IS NULL OR v_current THEN
    RETURN v_base;
  END IF;
  RETURN v_base || '@' || p_set;
END;
$function$;

-- Lock the set at finalize: the edge function writes assessment_source = 'v2fcq'
-- with the facet raws; this fills fcq_block_set once, from the answered blocks.
CREATE OR REPLACE FUNCTION public.hiregauge_fcq_lock_block_set_trg()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.assessment_source = 'v2fcq' AND NEW.fcq_block_set IS NULL THEN
    NEW.fcq_block_set := public.hiregauge_fcq_candidate_set(NEW.id);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_fcq_lock_block_set ON public.hiring_candidates;
CREATE TRIGGER trg_fcq_lock_block_set
  BEFORE UPDATE OF assessment_source ON public.hiring_candidates
  FOR EACH ROW EXECUTE FUNCTION public.hiregauge_fcq_lock_block_set_trg();

-- ---------------------------------------------------------------------------
-- 4. Backfill the lock for everyone who has answered any ranking block.
-- ---------------------------------------------------------------------------
UPDATE public.hiring_candidates c
SET fcq_block_set = s.set_key
FROM (
  SELECT DISTINCT r.candidate_id, public.hiregauge_fcq_candidate_set(r.candidate_id) AS set_key
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE i.section = 'newtworks_v2_personality_fc_quad'
) s
WHERE c.id = s.candidate_id AND c.fcq_block_set IS NULL;

DO $$
DECLARE v_n int; v_other int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE fcq_block_set IS DISTINCT FROM 'quad75')
    INTO v_n, v_other
  FROM public.hiring_candidates c
  WHERE EXISTS (SELECT 1 FROM public.hiregauge_candidate_responses r
                JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
                WHERE r.candidate_id = c.id AND i.section = 'newtworks_v2_personality_fc_quad');
  IF v_n < 43 OR v_other <> 0 THEN
    RAISE EXCEPTION 'fcq_block_set backfill unexpected: % candidates with blocks answered, % not on quad75', v_n, v_other;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Frozen copies of the 25 quad75 norm rows (values identical, unused until retirement).
-- ---------------------------------------------------------------------------
INSERT INTO public.hiregauge_facet_norms
  (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes,
   updated_at, updated_by, items_reworded_after_norm)
SELECT n.agency_id, n.facet || '@quad75', n.ref_mean_0_100, n.ref_sd_0_100, n.source_scale, n.citation,
       'FROZEN 2026-09-11 copy of ' || n.facet || ' as it stood while block set quad75 was current (values identical). Original: ' || n.retrieved_from,
       'FROZEN norm for block set quad75 (75 blocks, items 701-775). Read by candidates locked to quad75 once the set is retired; never rebuilt, never pooled with another set. Original note: ' || n.notes,
       now(), 'claude_migration_fcq_block_sets_and_norm_routing', n.items_reworded_after_norm
FROM public.hiregauge_facet_norms n
WHERE n.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND n.facet LIKE 'fcq\_%'
  AND n.facet NOT LIKE '%@%'
ON CONFLICT (agency_id, facet) DO NOTHING;

DO $$
DECLARE v_n int; v_mismatch int;
BEGIN
  SELECT count(*) INTO v_n FROM public.hiregauge_facet_norms
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND facet LIKE 'fcq\_%@quad75';
  SELECT count(*) INTO v_mismatch
  FROM public.hiregauge_facet_norms a
  JOIN public.hiregauge_facet_norms b ON b.agency_id = a.agency_id AND b.facet = a.facet || '@quad75'
  WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND a.facet LIKE 'fcq\_%' AND a.facet NOT LIKE '%@%'
    AND (a.ref_mean_0_100 <> b.ref_mean_0_100 OR a.ref_sd_0_100 <> b.ref_sd_0_100);
  IF v_n <> 25 OR v_mismatch <> 0 THEN
    RAISE EXCEPTION 'frozen quad75 copies wrong: % rows, % value mismatches', v_n, v_mismatch;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 6. Patch the four consumers to pass the candidate's set (read, assert, rewrite).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_def text;
  v_stamp text := '  -- 2026-09-11 (ranking-block sets): the norm key now takes the candidate''s fcq_block_set; a retired set reads its frozen fcq_<facet>@<set> rows (migration fcq_block_sets_and_norm_routing).' || E'\n';
  v_old text;
  v_new text;
  v_n int;
BEGIN
  -- _assessment_character_parts: 7 call sites
  v_def := pg_get_functiondef('public._assessment_character_parts'::regproc);
  v_old := 'public.hiregauge_facet_norm_key(hc.assessment_source, ';
  v_new := 'public.hiregauge_facet_norm_key(hc.assessment_source, hc.fcq_block_set, ';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 7 THEN RAISE EXCEPTION '_assessment_character_parts: expected 7 norm-key calls, found %', v_n; END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position('AS $function$' || E'\n' IN v_def) = 0 THEN RAISE EXCEPTION '_assessment_character_parts: body marker not found'; END IF;
  v_def := replace(v_def, 'AS $function$' || E'\n', 'AS $function$' || E'\n' || v_stamp);
  EXECUTE v_def;

  -- assessment_commitment: 6 call sites
  v_def := pg_get_functiondef('public.assessment_commitment'::regproc);
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 6 THEN RAISE EXCEPTION 'assessment_commitment: expected 6 norm-key calls, found %', v_n; END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position('AS $function$' || E'\n' IN v_def) = 0 THEN RAISE EXCEPTION 'assessment_commitment: body marker not found'; END IF;
  v_def := replace(v_def, 'AS $function$' || E'\n', 'AS $function$' || E'\n' || v_stamp);
  EXECUTE v_def;

  -- hiregauge_candidate_facet_percentiles: 1 call site + the two column lists feeding it
  v_def := pg_get_functiondef('public.hiregauge_candidate_facet_percentiles'::regproc);
  v_old := 'public.hiregauge_facet_norm_key(u.assessment_source, u.facet)';
  v_new := 'public.hiregauge_facet_norm_key(u.assessment_source, u.fcq_block_set, u.facet)';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'hiregauge_candidate_facet_percentiles: expected 1 norm-key call, found %', v_n; END IF;
  v_def := replace(v_def, v_old, v_new);
  v_old := 'SELECT agency_id, assessment_source, achievement_striving,';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'hiregauge_candidate_facet_percentiles: cand column list not found once (found %)', v_n; END IF;
  v_def := replace(v_def, v_old, 'SELECT agency_id, assessment_source, fcq_block_set, achievement_striving,');
  v_old := 'SELECT c.agency_id, c.assessment_source, v.facet, v.raw';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION 'hiregauge_candidate_facet_percentiles: unpivot column list not found once (found %)', v_n; END IF;
  v_def := replace(v_def, v_old, 'SELECT c.agency_id, c.assessment_source, c.fcq_block_set, v.facet, v.raw');
  IF position('AS $function$' || E'\n' IN v_def) = 0 THEN RAISE EXCEPTION 'hiregauge_candidate_facet_percentiles: body marker not found'; END IF;
  v_def := replace(v_def, 'AS $function$' || E'\n', 'AS $function$' || E'\n' || v_stamp);
  EXECUTE v_def;

  -- _newtworks_role_fit_core: 1 call site (the 25 self-report facets share it)
  v_def := pg_get_functiondef('public._newtworks_role_fit_core'::regproc);
  v_old := 'public.hiregauge_facet_norm_key(p_candidate.assessment_source, v_name)';
  v_new := 'public.hiregauge_facet_norm_key(p_candidate.assessment_source, p_candidate.fcq_block_set, v_name)';
  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN RAISE EXCEPTION '_newtworks_role_fit_core: expected 1 norm-key call, found %', v_n; END IF;
  v_def := replace(v_def, v_old, v_new);
  IF position('AS $function$' || E'\n' IN v_def) = 0 THEN RAISE EXCEPTION '_newtworks_role_fit_core: body marker not found'; END IF;
  v_def := replace(v_def, 'AS $function$' || E'\n', 'AS $function$' || E'\n' || v_stamp);
  EXECUTE v_def;
END $$;

-- ---------------------------------------------------------------------------
-- 7. Auto-rebuild of the current set's norms (mirrors hiregauge_gma_norm_rebuild_current_set).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_fcq_norm_rebuild_current_set(p_agency uuid, p_force boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
-- Rebuilds the plain 'fcq_<facet>' norm rows for the CURRENT ranking-block set from
-- completed sittings ON THAT SET once N >= hiregauge_fcq_block_sets.norm_rebuild_min_n,
-- then refreshes the scoring cache. No-op while the count is short or the set is
-- already rebuilt (p_force re-runs it, e.g. the N>=50 refresh). A completion = a
-- candidate locked to the set, assessment_source v2fcq, assessment_completed_at set,
-- not a test candidate, reliability written and not 'low', who answered every block
-- of the set at sitting 1. Mean and sample SD of compute_newtworks_v2fcq_facets_as_row
-- (id, 1) per facet -- the exact population and formula behind the 2026-09-10 rebuild
-- (migration fcq_facet_norms_rebuild_n26), which this reproduces to the hundredth.
-- A facet with fewer than 2 scored candidates or zero spread keeps its current row.
-- Frozen '@<set>' rows are never touched.
DECLARE
  v_set text;
  v_status text;
  v_min_n int;
  v_size int;
  v_n int;
  v_written int;
  v_scale text := 'newtworks_v2fcq forced-choice quad ranking, 0-100 (evidence/comparisons*100 over 36 comparisons per facet; direction per statement pole tag)';
  v_citation text := 'LOCAL POOL NORM (norm-referenced interpretation: Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014). Format basis: Brown & Maydeu-Olivares 2011 EPM 71:460-502; Schulte, Holling & Burkner 2021 EPM; Hontangas et al. 2015 APM 39:598-612; Cao & Drasgow 2019 JAP 104:1347-1368.';
BEGIN
  SELECT set_key, norm_status, norm_rebuild_min_n INTO v_set, v_status, v_min_n
  FROM public.hiregauge_fcq_block_sets WHERE agency_id = p_agency AND is_current;
  IF v_set IS NULL THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'no_current_set');
  END IF;
  IF v_status = 'rebuilt' AND NOT p_force THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'already_rebuilt', 'set_key', v_set);
  END IF;

  SELECT count(*)::int INTO v_size FROM public.hiregauge_fcq_block_set_members WHERE set_key = v_set;

  CREATE TEMP TABLE IF NOT EXISTS fcq_norm_done (id uuid PRIMARY KEY) ON COMMIT DROP;
  DELETE FROM fcq_norm_done;
  INSERT INTO fcq_norm_done (id)
  SELECT c.id
  FROM public.hiring_candidates c
  WHERE c.agency_id = p_agency
    AND c.fcq_block_set = v_set
    AND c.assessment_source = 'v2fcq'
    AND c.assessment_completed_at IS NOT NULL
    AND c.is_test_candidate IS NOT TRUE
    AND c.reliability IS NOT NULL
    AND c.reliability <> 'low'
    AND (SELECT count(*) FROM public.hiregauge_candidate_responses r
         JOIN public.hiregauge_fcq_block_set_members m ON m.item_id = r.item_id AND m.set_key = v_set
         WHERE r.candidate_id = c.id AND r.sitting = 1) = v_size;

  SELECT count(*)::int INTO v_n FROM fcq_norm_done;

  IF v_n < v_min_n AND NOT p_force THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'waiting_for_n', 'set_key', v_set, 'n', v_n, 'min_n', v_min_n);
  END IF;
  IF v_n < 2 THEN
    RETURN jsonb_build_object('rebuilt', false, 'reason', 'too_few', 'set_key', v_set, 'n', v_n);
  END IF;

  INSERT INTO public.hiregauge_facet_norms
    (agency_id, facet, ref_mean_0_100, ref_sd_0_100, source_scale, citation, retrieved_from, notes,
     updated_at, updated_by, items_reworded_after_norm)
  SELECT p_agency,
         'fcq_' || f.hypothesized_trait,
         round(avg(f.facet_score)::numeric, 2),
         round(stddev_samp(f.facet_score)::numeric, 2),
         v_scale,
         v_citation,
         format('REBUILT %s from %s completed sittings on ranking-block set %s (hiregauge_fcq_norm_rebuild_current_set): mean/sample SD of compute_newtworks_v2fcq_facets_as_row(id,1), non-test, reliability not low.', now()::date, v_n, v_set),
         format('Local applicant-pool norm for ranking-block set %s, N=%s. Refresh at N>=50 on the same set (p_force). NORM IS TIED TO THE BLOCK SET: frozen as fcq_<facet>@%s when the set retires; never pool across sets.', v_set, v_n, v_set),
         now(),
         'hiregauge_fcq_norm_rebuild_current_set',
         false
  FROM fcq_norm_done d
  CROSS JOIN LATERAL public.compute_newtworks_v2fcq_facets_as_row(d.id, 1) f
  GROUP BY f.hypothesized_trait
  HAVING count(*) >= 2 AND stddev_samp(f.facet_score) > 0
  ON CONFLICT (agency_id, facet) DO UPDATE
    SET ref_mean_0_100 = EXCLUDED.ref_mean_0_100,
        ref_sd_0_100   = EXCLUDED.ref_sd_0_100,
        retrieved_from = EXCLUDED.retrieved_from,
        notes          = EXCLUDED.notes,
        updated_at     = EXCLUDED.updated_at,
        updated_by     = EXCLUDED.updated_by;
  GET DIAGNOSTICS v_written = ROW_COUNT;

  UPDATE public.hiregauge_fcq_block_sets SET norm_status = 'rebuilt', updated_at = now() WHERE set_key = v_set;

  -- the norm writes bumped hiregauge_scoring_version via trigger; recompute caches
  PERFORM public.hiregauge_refresh_scoring_cache(p_agency, 'all');

  INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
  VALUES (p_agency, 'assessment_norm_rebuilt', 'info',
          format('Personality norms rebuilt for ranking-block set %s', v_set),
          format('The compared-to-average personality norms for ranking-block set %s were rebuilt from %s completed sittings (%s facet rows written). Every candidate on this set was rescored.', v_set, v_n, v_written),
          'hiring', false, false);

  RETURN jsonb_build_object('rebuilt', true, 'set_key', v_set, 'n', v_n, 'facets_written', v_written);
END;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_fcq_norm_auto_rebuild_trg()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  BEGIN
    PERFORM public.hiregauge_fcq_norm_rebuild_current_set(NEW.agency_id, false);
  EXCEPTION WHEN OTHERS THEN
    -- Never let a norm rebuild block a candidate's scoring write.
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
    VALUES (NEW.agency_id, 'assessment_norm_rebuild_failed', 'warning',
            'Personality norm auto-rebuild failed',
            format('hiregauge_fcq_norm_rebuild_current_set raised: %s. Run it by hand: SELECT public.hiregauge_fcq_norm_rebuild_current_set(agency, false).', SQLERRM),
            'hiring', false, false);
  END;
  RETURN NEW;
END;
$function$;

-- Finalize writes assessment_completed_at first and reliability in a later call, so
-- the trigger watches both: the rebuild counts only sittings with reliability written.
DROP TRIGGER IF EXISTS trg_fcq_norm_auto_rebuild ON public.hiring_candidates;
CREATE TRIGGER trg_fcq_norm_auto_rebuild
  AFTER UPDATE OF assessment_completed_at, reliability ON public.hiring_candidates
  FOR EACH ROW
  WHEN (NEW.assessment_source = 'v2fcq'
        AND NEW.assessment_completed_at IS NOT NULL
        AND NEW.reliability IS NOT NULL
        AND (OLD.assessment_completed_at IS DISTINCT FROM NEW.assessment_completed_at
             OR OLD.reliability IS DISTINCT FROM NEW.reliability))
  EXECUTE FUNCTION public.hiregauge_fcq_norm_auto_rebuild_trg();

-- ---------------------------------------------------------------------------
-- 8. Self-check: nobody's numbers moved. Then refresh caches (the frozen-copy insert
--    bumped hiregauge_scoring_version).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_before int;
  v_after int;
  v_diff int;
  v_reproduce jsonb;
BEGIN
  CREATE TEMP TABLE fcq_step4_after AS
  SELECT c.id,
         v.capability_score, v.character_score, v.commitment_score, v.composite, v.verdict,
         (SELECT jsonb_object_agg(p.facet, p.percentile)
            FROM public.hiregauge_candidate_facet_percentiles(c.id) p) AS pct
  FROM public.hiring_candidates c
  CROSS JOIN LATERAL public.verdict_assessment(c.id, NULL) v
  WHERE c.assessment_source = 'v2fcq';

  SELECT count(*) INTO v_before FROM fcq_step4_before;
  SELECT count(*) INTO v_after FROM fcq_step4_after;
  SELECT count(*) INTO v_diff
  FROM fcq_step4_before b
  FULL JOIN fcq_step4_after a ON a.id = b.id
  WHERE a.id IS NULL OR b.id IS NULL
     OR a.capability_score IS DISTINCT FROM b.capability_score
     OR a.character_score  IS DISTINCT FROM b.character_score
     OR a.commitment_score IS DISTINCT FROM b.commitment_score
     OR a.composite        IS DISTINCT FROM b.composite
     OR a.verdict          IS DISTINCT FROM b.verdict
     OR a.pct              IS DISTINCT FROM b.pct;
  IF v_before < 27 OR v_before <> v_after OR v_diff <> 0 THEN
    RAISE EXCEPTION 'self-check failed: % candidates before, % after, % changed', v_before, v_after, v_diff;
  END IF;

  -- The current set is already rebuilt, so the auto-rebuild must be a no-op here.
  v_reproduce := public.hiregauge_fcq_norm_rebuild_current_set('126794dd-25ff-47d2-a436-724499733365', false);
  IF (v_reproduce->>'rebuilt')::boolean OR v_reproduce->>'reason' <> 'already_rebuilt' THEN
    RAISE EXCEPTION 'auto-rebuild should be a no-op on quad75, got %', v_reproduce;
  END IF;

  PERFORM public.hiregauge_refresh_scoring_cache('126794dd-25ff-47d2-a436-724499733365', 'all');
END $$;
