-- GMA item sets: infrastructure for changing the Section 1 GMA item set
-- without breaking candidates mid-sitting, norms, or the chance floor.
-- Step 1 of 2 (this migration): tables, functions, backfill, function edits.
-- NO candidate-visible behaviour changes here -- the 2026-08-02 set stays
-- current and active. Step 2 (gma_section1_swap_fixed16_v2) does the flip.
--
-- WHY TWO STEPS: the edge function that serves Section 1 has to be deployed
-- between them. If the items flipped first, the old function would serve
-- the new items to the 25 candidates who already finished the old GMA
-- items and are mid-assessment, and reject their saves. Deploy order:
-- this migration -> v1-assessment redeploy -> the swap migration.
--
-- WHAT THIS ADDS
-- 1. hiregauge_gma_item_sets / hiregauge_gma_item_set_members: named GMA
--    item sets. Exactly one is current. A set can pin the raw-percent
--    reasoning floor and the stint-1 hard-eliminator threshold by override
--    (used to keep the retired set on the values Peter ruled on 2026-09-02).
-- 2. hiring_candidates.gma_item_set: the set a candidate is locked to, set
--    on their first GMA answer (edge fn via hiregauge_gma_accept_item) and
--    backfilled here for everyone who has already answered a GMA item.
-- 3. hiregauge_gma_chance_floor(candidate): chance mean, SD and the
--    chance + 2 SD floor computed from the REAL option counts of the items
--    in the candidate's set (6-option pattern/numerical/verbal, 3-option
--    deductive), with the exact Poisson-binomial tail probability. The
--    2026-08-05 derivation of 62.5% assumed 2-option items; true chance + 2
--    SD on the 2026-08 set is 7 of 16 (43.75%). That set is pinned to 62.5%
--    by override because Peter ruled on it 2026-09-02; the derivation
--    applies to every later set.
-- 4. Per-set norm routing: hiregauge_gma_norm_facet('gma', set) -> 'gma'
--    for the current set, 'gma@<set>' for a retired set. A norm describes one
--    item set (Nunnally & Bernstein 1994; AERA/APA/NCME Standards 2014);
--    completions are never pooled across sets. Candidates on a retired set
--    keep scoring against that set's frozen norm.
-- 5. hiregauge_gma_speed_ipm(candidate): the v5_5 correct-items-only speed
--    metric, moved out of _newtworks_role_fit_core so the score and the norm
--    rebuild share one formula.
-- 6. hiregauge_gma_norm_rebuild_current_set(agency): rebuilds the current
--    set's provisional 'gma' / 'gma_speed' rows once N >= norm_rebuild_min_n
--    (20) completions exist on that set, then refreshes the scoring cache.
--    Fired by a trigger on hiring_candidates.gma_total_accuracy so nobody has
--    to remember.
-- 7. _newtworks_reasoning_gate reads the set-aware floor. On the current
--    2026-08 set every number it produces is unchanged.

CREATE TABLE IF NOT EXISTS public.hiregauge_gma_item_sets (
  set_key                     text PRIMARY KEY,
  agency_id                   uuid NOT NULL,
  label                       text NOT NULL,
  is_current                  boolean NOT NULL DEFAULT false,
  activated_at                timestamptz NOT NULL DEFAULT now(),
  retired_at                  timestamptz,
  floor_pct_override          numeric,
  gate_c_max_correct_override integer,
  norm_status                 text NOT NULL DEFAULT 'provisional_seed'
                              CHECK (norm_status IN ('provisional_seed','rebuilt','frozen')),
  norm_rebuild_min_n          integer NOT NULL DEFAULT 20,
  notes                       text,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.hiregauge_gma_item_sets IS
  'Named Section 1 GMA item sets. Exactly one per agency is current. floor_pct_override / gate_c_max_correct_override pin the raw-percent reasoning floor and the stint-1 hard eliminator to ruled values; NULL means derive from option counts (hiregauge_gma_chance_floor). norm_status tracks whether the gma/gma_speed norm rows for the set are a provisional seed, rebuilt from >= norm_rebuild_min_n completions, or frozen (retired set).';

CREATE UNIQUE INDEX IF NOT EXISTS hiregauge_gma_item_sets_one_current
  ON public.hiregauge_gma_item_sets (agency_id) WHERE is_current;

CREATE TABLE IF NOT EXISTS public.hiregauge_gma_item_set_members (
  set_key  text NOT NULL REFERENCES public.hiregauge_gma_item_sets(set_key),
  item_id  uuid NOT NULL REFERENCES public.hiregauge_instrument_items(id),
  PRIMARY KEY (set_key, item_id)
);
CREATE INDEX IF NOT EXISTS hiregauge_gma_item_set_members_item_idx
  ON public.hiregauge_gma_item_set_members (item_id);

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS gma_item_set text REFERENCES public.hiregauge_gma_item_sets(set_key);
COMMENT ON COLUMN public.hiring_candidates.gma_item_set IS
  'GMA item set this candidate is locked to (hiregauge_gma_item_sets.set_key). Written on the first GMA answer; never changes afterwards. NULL = has not answered a GMA item yet (resolves to the current set).';

ALTER TABLE public.hiregauge_gma_item_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hiregauge_gma_item_set_members ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS authenticated_select_hiregauge_gma_item_sets ON public.hiregauge_gma_item_sets;
CREATE POLICY authenticated_select_hiregauge_gma_item_sets ON public.hiregauge_gma_item_sets
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS authenticated_select_hiregauge_gma_item_set_members ON public.hiregauge_gma_item_set_members;
CREATE POLICY authenticated_select_hiregauge_gma_item_set_members ON public.hiregauge_gma_item_set_members
  FOR SELECT TO authenticated USING (true);
