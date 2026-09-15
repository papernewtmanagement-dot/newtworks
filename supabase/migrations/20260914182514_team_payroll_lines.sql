-- Step 3 of the old Payroll Process manual page, made live. One row per recurring
-- payroll line per teammate. The three team columns stay the store for the
-- figures the CPR and the comp pool already read; this table carries the lines
-- they have no column for. Peter 2026-09-14.
CREATE TABLE IF NOT EXISTS public.team_payroll_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  line_type text NOT NULL CHECK (line_type IN ('life_stipend','medical','dental','vision','other_deduction')),
  label text,
  weekly_amount numeric(10,2) NOT NULL DEFAULT 0,
  monthly_premium numeric(10,2),
  agency_paid_weekly numeric(10,2),
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS team_payroll_lines_member_idx
  ON public.team_payroll_lines (team_member_id, is_active);

ALTER TABLE public.team_payroll_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_payroll_lines_read ON public.team_payroll_lines;
CREATE POLICY team_payroll_lines_read ON public.team_payroll_lines
  FOR SELECT TO authenticated USING (true);

-- Seed the two lines that only ever existed on the manual page.
INSERT INTO public.team_payroll_lines (agency_id, team_member_id, line_type, label, weekly_amount, monthly_premium)
SELECT '126794dd-25ff-47d2-a436-724499733365', t.id, 'life_stipend', 'Life insurance stipend', 43.81, 189.85
FROM public.team t WHERE t.first_name='Leslie' AND t.last_name='Jones' AND t.is_active
  AND NOT EXISTS (SELECT 1 FROM public.team_payroll_lines x WHERE x.team_member_id=t.id AND x.line_type='life_stipend');

INSERT INTO public.team_payroll_lines (agency_id, team_member_id, line_type, label, weekly_amount, monthly_premium)
SELECT '126794dd-25ff-47d2-a436-724499733365', t.id, 'life_stipend', 'Life insurance stipend', 11.54, 50.00
FROM public.team t WHERE t.first_name='Thomas' AND t.last_name='Lynch' AND t.is_active
  AND NOT EXISTS (SELECT 1 FROM public.team_payroll_lines x WHERE x.team_member_id=t.id AND x.line_type='life_stipend');

INSERT INTO public.team_payroll_lines (agency_id, team_member_id, line_type, label, weekly_amount)
SELECT '126794dd-25ff-47d2-a436-724499733365', t.id, 'other_deduction', 'VA Child Support', 25.80
FROM public.team t WHERE t.first_name='Thomas' AND t.last_name='Lynch' AND t.is_active
  AND NOT EXISTS (SELECT 1 FROM public.team_payroll_lines x WHERE x.team_member_id=t.id AND x.line_type='other_deduction');

-- Leslie's life stipend existed only on the manual page; put it on her team row
-- too so the column the CPR reads and the line agree.
UPDATE public.team SET weekly_life_benefit_agency_paid = 43.81, updated_at = NOW()
WHERE first_name='Leslie' AND last_name='Jones' AND is_active
  AND weekly_life_benefit_agency_paid IS NULL;
