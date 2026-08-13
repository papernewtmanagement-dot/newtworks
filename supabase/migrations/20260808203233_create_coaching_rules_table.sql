-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-08 20:32:33 UTC (ledger name: create_coaching_rules_table) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260808203233.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE TABLE IF NOT EXISTS public.coaching_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  category text NOT NULL,           -- 'fit_step' | 'sales_method' | future: 'objection', 'retention', 'delivery', ...
  fit_step text,                    -- for category='fit_step': the fit_scorecards score column name (demeanor_score, frogs_score, ...); NULL otherwise
  title text NOT NULL,
  content text NOT NULL,            -- the rule/tip itself, house markdown; for fit_step rows: "Job: ... Move: ..."
  source text,                      -- book / manual attribution
  sort_order int NOT NULL DEFAULT 100,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_coaching_rules_lookup
  ON public.coaching_rules (agency_id, category, sort_order)
  WHERE is_active;

ALTER TABLE public.coaching_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS coaching_rules_admin_read ON public.coaching_rules;
CREATE POLICY coaching_rules_admin_read ON public.coaching_rules
  FOR SELECT TO authenticated
  USING ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND is_agency_admin());

DROP POLICY IF EXISTS coaching_rules_admin_insert ON public.coaching_rules;
CREATE POLICY coaching_rules_admin_insert ON public.coaching_rules
  FOR INSERT TO authenticated
  WITH CHECK ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND is_agency_admin());

DROP POLICY IF EXISTS coaching_rules_admin_update ON public.coaching_rules;
CREATE POLICY coaching_rules_admin_update ON public.coaching_rules
  FOR UPDATE TO authenticated
  USING ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND is_agency_admin());

DROP POLICY IF EXISTS coaching_rules_admin_delete ON public.coaching_rules;
CREATE POLICY coaching_rules_admin_delete ON public.coaching_rules
  FOR DELETE TO authenticated
  USING ((agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid) AND is_agency_admin());
