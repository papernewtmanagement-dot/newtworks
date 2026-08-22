-- Team compensation pool % schedule by week-ending date.
-- Stores the weekly target pool percentage applied to the pool basis
-- to derive the team comp envelope each week. Basis is computed at runtime
-- from live commission + on-time SMVC$ + on-time Scorecard$; this table
-- stores only the percentage and metadata.

CREATE TABLE IF NOT EXISTS public.team_comp_pool_schedule (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id UUID NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  week_end_date DATE NOT NULL,
  pool_pct NUMERIC(7,5) NOT NULL,
  phase TEXT NOT NULL CHECK (phase IN (
    'phase_1_aa05_rampdown',
    'phase_3_aa28_rampdown'
  )),
  basis_regime TEXT NOT NULL CHECK (basis_regime IN ('AA05','AA28')),
  plan_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (agency_id, week_end_date)
);

CREATE INDEX IF NOT EXISTS idx_team_comp_pool_schedule_agency_week
  ON public.team_comp_pool_schedule(agency_id, week_end_date);

ALTER TABLE public.team_comp_pool_schedule ENABLE ROW LEVEL SECURITY;

-- Service-role-only by default; UI will add policies as needed
COMMENT ON TABLE public.team_comp_pool_schedule IS 
'Weekly target pool % for team compensation residual-pool design. Phase 1 ramps 45%->40% across 7/11/2026 - 12/25/2027 (AA05 basis). Phase 3 ramps 44.16%->40% across 1/1/2028 - 12/30/2028 (AA28 basis). The 12/25/2027 -> 1/1/2028 transition holds $/wk constant; % bumps because basis compresses (Auto 8->6).';

