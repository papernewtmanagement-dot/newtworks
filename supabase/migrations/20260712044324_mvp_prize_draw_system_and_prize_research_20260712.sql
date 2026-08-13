-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 04:43:24 UTC (ledger name: mvp_prize_draw_system_and_prize_research_20260712) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712044324.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- MVP prize-draw system tables + prize-cart quarter-refresh workflow storage
-- Locked 2026-07-12. Companion to handbook Winning & Learning MVP tiers.

CREATE TABLE IF NOT EXISTS public.mvp_draw_tiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  min_new_sp numeric NOT NULL,
  draws int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(agency_id, min_new_sp)
);

ALTER TABLE public.mvp_draw_tiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mvp_draw_tiers_read ON public.mvp_draw_tiers;
CREATE POLICY mvp_draw_tiers_read ON public.mvp_draw_tiers FOR SELECT USING (true);
DROP POLICY IF EXISTS mvp_draw_tiers_write ON public.mvp_draw_tiers;
CREATE POLICY mvp_draw_tiers_write ON public.mvp_draw_tiers FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

INSERT INTO public.mvp_draw_tiers (agency_id, min_new_sp, draws) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 100, 1),
  ('126794dd-25ff-47d2-a436-724499733365', 300, 2),
  ('126794dd-25ff-47d2-a436-724499733365', 500, 3)
ON CONFLICT (agency_id, min_new_sp) DO NOTHING;

-- Audit trail for prize draws (each drawn prize per MVP week, whether selected as final favorite)
CREATE TABLE IF NOT EXISTS public.mvp_prize_draws_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  mvp_history_id uuid NOT NULL REFERENCES public.mvp_history(id) ON DELETE CASCADE,
  prize_cart_id uuid NOT NULL REFERENCES public.prize_cart(id) ON DELETE CASCADE,
  draw_number int NOT NULL,
  was_selected boolean NOT NULL DEFAULT false,
  drawn_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(mvp_history_id, draw_number)
);

ALTER TABLE public.mvp_prize_draws_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mvp_prize_draws_log_read ON public.mvp_prize_draws_log;
CREATE POLICY mvp_prize_draws_log_read ON public.mvp_prize_draws_log FOR SELECT USING (true);
DROP POLICY IF EXISTS mvp_prize_draws_log_write ON public.mvp_prize_draws_log;
CREATE POLICY mvp_prize_draws_log_write ON public.mvp_prize_draws_log FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- Quarter-refresh pending research state (populated by quarter_close, consumed by Claude session)
CREATE TABLE IF NOT EXISTS public.pending_prize_research (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  quarter_ending_date date NOT NULL,
  available_budget_dollars numeric NOT NULL,
  carried_prize_count int NOT NULL DEFAULT 0,
  carried_prize_value_total numeric NOT NULL DEFAULT 0,
  broken_link_ids uuid[] NOT NULL DEFAULT '{}',
  broken_link_details jsonb NOT NULL DEFAULT '[]'::jsonb,
  status text NOT NULL DEFAULT 'pending',
  claude_run_at timestamptz,
  peter_approved_at timestamptz,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(agency_id, quarter_ending_date),
  CHECK (status IN ('pending','in_research','awaiting_approval','completed','skipped'))
);

ALTER TABLE public.pending_prize_research ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pending_prize_research_read ON public.pending_prize_research;
CREATE POLICY pending_prize_research_read ON public.pending_prize_research FOR SELECT USING (true);
DROP POLICY IF EXISTS pending_prize_research_write ON public.pending_prize_research;
CREATE POLICY pending_prize_research_write ON public.pending_prize_research FOR ALL USING (auth.role() = 'authenticated') WITH CHECK (auth.role() = 'authenticated');

-- Verify
SELECT 'mvp_draw_tiers' AS t, COUNT(*) FROM public.mvp_draw_tiers WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
UNION ALL SELECT 'mvp_prize_draws_log', COUNT(*) FROM public.mvp_prize_draws_log
UNION ALL SELECT 'pending_prize_research', COUNT(*) FROM public.pending_prize_research;
