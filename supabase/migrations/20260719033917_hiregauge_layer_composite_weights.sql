-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-19 03:39:17 UTC (ledger name: hiregauge_layer_composite_weights) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260719033917.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

CREATE TABLE IF NOT EXISTS public.hiregauge_layer_composite_weights (
  layer      text NOT NULL,
  construct  text NOT NULL,
  weight     numeric NOT NULL CHECK (weight >= 0 AND weight <= 1),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (layer, construct),
  CHECK (layer IN ('resume','assessment','interview','reference')),
  CHECK (construct IN ('nature','nurture','drivers'))
);

COMMENT ON TABLE public.hiregauge_layer_composite_weights IS
  'Normalized within-layer construct weights. Each layer''s three weights (nature/nurture/drivers) sum to 1.0 and determine how that layer''s composite/total is computed from its three construct scores. Used by v_hiring_candidates.res_composite (resume layer only) and by hiregauge_three_construct_verdict (all four layers, v_row_*). Distinct from the un-normalized layer→construct contribution weights (v_nature_r_w etc.) which drive CONSTRUCT totals across layers.';

ALTER TABLE public.hiregauge_layer_composite_weights ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hlcw_read ON public.hiregauge_layer_composite_weights;
CREATE POLICY hlcw_read
  ON public.hiregauge_layer_composite_weights
  FOR SELECT
  TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS hlcw_service_all ON public.hiregauge_layer_composite_weights;
CREATE POLICY hlcw_service_all
  ON public.hiregauge_layer_composite_weights
  FOR ALL
  TO service_role
  USING (true) WITH CHECK (true);

GRANT SELECT ON public.hiregauge_layer_composite_weights TO anon, authenticated;
GRANT ALL    ON public.hiregauge_layer_composite_weights TO service_role;

INSERT INTO public.hiregauge_layer_composite_weights (layer, construct, weight) VALUES
  ('resume',     'nature',  0.2000),
  ('resume',     'nurture', 0.4000),
  ('resume',     'drivers', 0.4000),
  ('assessment', 'nature',  0.6522),
  ('assessment', 'nurture', 0.1304),
  ('assessment', 'drivers', 0.2174),
  ('interview',  'nature',  0.1429),
  ('interview',  'nurture', 0.4286),
  ('interview',  'drivers', 0.4286),
  ('reference',  'nature',  0.0909),
  ('reference',  'nurture', 0.5455),
  ('reference',  'drivers', 0.3636)
ON CONFLICT (layer, construct) DO NOTHING;
