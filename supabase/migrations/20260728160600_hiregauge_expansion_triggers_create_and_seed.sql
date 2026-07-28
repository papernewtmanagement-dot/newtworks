-- Newtworks v1 Stint 2 build, step 8 of 10 per handoff 2026-07-28.
-- Governs when scoring says "candidate needs more items to firm up
-- the read." Step 9's scoring function reads this and returns the
-- list of sections to expand.
--
-- signal_type explains WHICH quantity we're checking:
--   trait_score           : per-trait raw 0-100 score
--   section_score         : whole-section score (used for cognitive)
--   impression_mgmt_score : validity — how much the person is dressing up
--   nonsense_inflation    : validity — how often they endorsed a fake vocab word
--   retest_divergence     : reliability — average gap between item pairs
--
-- low_bound / high_bound define the WINDOW that fires. Both NULL means
-- always-on (not used today). One NULL side means one-sided
-- (e.g. low_bound=70, high_bound=NULL → fires at ≥70).
--
-- expansion_section + expansion_trait + expansion_count describe what
-- extra items to serve. expansion_count NULL means "serve every stint=2
-- item that matches the expansion scope."
CREATE TABLE IF NOT EXISTS public.hiregauge_expansion_triggers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id          uuid NOT NULL,
  trigger_name       text NOT NULL,
  signal_type        text NOT NULL CHECK (signal_type IN (
    'trait_score',
    'section_score',
    'impression_mgmt_score',
    'nonsense_inflation',
    'retest_divergence'
  )),
  signal_trait       text,
  signal_section     text,
  low_bound          numeric,
  high_bound         numeric,
  action             text NOT NULL,
  expansion_section  text,
  expansion_trait    text,
  expansion_count    integer,
  is_active          boolean NOT NULL DEFAULT true,
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hiregauge_expansion_triggers_agency_active
  ON public.hiregauge_expansion_triggers (agency_id, is_active);

CREATE INDEX IF NOT EXISTS idx_hiregauge_expansion_triggers_signal
  ON public.hiregauge_expansion_triggers (signal_type, signal_trait, signal_section)
  WHERE is_active = true;

ALTER TABLE public.hiregauge_expansion_triggers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hiregauge_expansion_triggers_agency_isolation
  ON public.hiregauge_expansion_triggers;

CREATE POLICY hiregauge_expansion_triggers_agency_isolation
  ON public.hiregauge_expansion_triggers
  FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365')
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365');

-- Seed v1 rules from handoff 2026-07-28.
-- Rule (a): trait score 45-55 → expand that trait's stint=2 items.
-- One row per trait so each fires independently.
INSERT INTO public.hiregauge_expansion_triggers
  (agency_id, trigger_name, signal_type, signal_trait, low_bound, high_bound,
   action, expansion_section, expansion_trait, expansion_count, notes)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'borderline_trait_' || trait,
  'trait_score',
  trait,
  45, 55,
  'expand_trait_stint_2',
  'newtworks_v1_personality',
  trait,
  NULL,
  'Serve every stint=2 item for this trait; scoring recomputes on merged responses.'
FROM (VALUES
  ('recognition_drive'),
  ('analytical'),
  ('assertiveness'),
  ('belief_in_others'),
  ('compassion'),
  ('deadline_motivation'),
  ('independent_spirit'),
  ('optimism'),
  ('self_promotion')
) AS t(trait);

-- Rule (b): cognitive borderline 40-60 → +5 more cognitive items.
INSERT INTO public.hiregauge_expansion_triggers
  (agency_id, trigger_name, signal_type, signal_section, low_bound, high_bound,
   action, expansion_section, expansion_count, notes)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'borderline_cognitive',
  'section_score',
  'cognitive',
  40, 60,
  'expand_cognitive',
  'cognitive',
  5,
  'ICAR items live in section=cognitive. Step 4 loads ~15-20 of them; this rule serves 5 more when the initial read is borderline.'
);

-- Rule (c): impression management OR nonsense inflation → +extra IM + nonsense.
-- Modeled as two rows so either side triggers independently.
-- expansion_count NULL means "everything stint=2 in the target sections."
INSERT INTO public.hiregauge_expansion_triggers
  (agency_id, trigger_name, signal_type, low_bound, high_bound,
   action, expansion_section, expansion_count, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'elevated_impression_mgmt',
   'impression_mgmt_score',
   70, NULL,
   'expand_impression_mgmt_and_nonsense',
   'newtworks_v1_impression_mgmt',
   NULL,
   'Companion nonsense expansion handled in step 9 dispatcher: same trigger fires expansion in newtworks_v1_vct nonsense subset too.'),
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'nonsense_inflation',
   'nonsense_inflation',
   2, NULL,
   'expand_impression_mgmt_and_nonsense',
   'newtworks_v1_impression_mgmt',
   NULL,
   'Fires when candidate endorses ≥2 fabricated vocab words (step 6). Companion nonsense expansion same as above.');

-- Rule (d): retest divergence >2 avg → more retest pairs.
INSERT INTO public.hiregauge_expansion_triggers
  (agency_id, trigger_name, signal_type, low_bound, high_bound,
   action, expansion_count, notes)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'retest_divergence_high',
  'retest_divergence',
  2, NULL,
  'expand_retest_pairs',
  3,
  'Step 7 seeds 5 retest duplicates (stint=1). If divergence >2 avg, serve 3 more retest pairs from stint=2 pool. Retest items span sections via retest_of_item_number FK.'
);
