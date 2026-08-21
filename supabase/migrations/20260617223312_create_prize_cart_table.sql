CREATE TABLE IF NOT EXISTS public.prize_cart (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  quarter_ending_date date NOT NULL,
  display_order integer NOT NULL CHECK (display_order BETWEEN 1 AND 13),
  prize_description text NOT NULL,
  prize_value numeric(10,2),
  winner_team_member_id uuid REFERENCES public.team(id),
  won_on date,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, quarter_ending_date, display_order)
);

CREATE INDEX IF NOT EXISTS idx_prize_cart_agency_quarter
  ON public.prize_cart (agency_id, quarter_ending_date, display_order);

ALTER TABLE public.prize_cart ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "prize_cart_anon_select" ON public.prize_cart;
CREATE POLICY "prize_cart_anon_select" ON public.prize_cart FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS "prize_cart_authenticated_all" ON public.prize_cart;
CREATE POLICY "prize_cart_authenticated_all" ON public.prize_cart FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT ON public.prize_cart TO anon;
GRANT ALL ON public.prize_cart TO authenticated;
