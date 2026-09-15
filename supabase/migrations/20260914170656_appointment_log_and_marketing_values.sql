-- Appointments (Peter rulings 2026-09-11, built 2026-09-14).
-- ONE record that moves through states, the same shape as a policy going
-- submitted then issued: marked set, then kept, then sold. Not three rows.
-- Setting an appointment pays nothing. Kept and Sold only pay when the
-- appointment was pivot escalated to someone else, and the money belongs to
-- the person who escalated it, never the person who sold it — the seller is
-- already paid by Sales Points and the multiline.
CREATE TABLE IF NOT EXISTS public.appointment_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL,                 -- who set it; the earner when escalated
  escalated_to_team_member_id uuid,             -- who it was handed to; null = kept for themselves, pays nothing
  customer_first_name text,
  customer_last_initial text,
  customer_label text,
  phone_last4 text,
  set_on date NOT NULL,
  week_end_date date NOT NULL,
  kept_on date,
  no_show_on date,
  sold_on date,
  note text,
  ecrm_url text,
  status text NOT NULL DEFAULT 'active',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  voided_at timestamptz,
  voided_by uuid,
  void_reason text
);
ALTER TABLE public.appointment_log ADD COLUMN IF NOT EXISTS no_show_on date;
CREATE INDEX IF NOT EXISTS idx_appointment_log_week ON public.appointment_log (agency_id, week_end_date);
CREATE INDEX IF NOT EXISTS idx_appointment_log_open ON public.appointment_log (agency_id, status, sold_on);

ALTER TABLE public.appointment_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS appointment_log_rw ON public.appointment_log;
CREATE POLICY appointment_log_rw ON public.appointment_log
  FOR ALL TO authenticated
  USING (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()))
  WITH CHECK (agency_id IN (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid()));

DROP TRIGGER IF EXISTS trg_change_log ON public.appointment_log;
CREATE TRIGGER trg_change_log AFTER INSERT OR DELETE OR UPDATE ON public.appointment_log
FOR EACH ROW EXECUTE FUNCTION public.log_change();

-- The two paying events. Set is deliberately absent: it pays nothing.
INSERT INTO public.marketing_point_values (agency_id, event_key, label, base_points, step_per_prior, prior_cap, description, sort_order, is_active)
VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'appointment_kept', 'Appointment Kept', 5.00, 0.00, 0,
  'An appointment you set and handed to someone else was kept. $5 flat. Setting an appointment pays nothing, and an appointment you keep for yourself pays nothing here — that one pays through the sale.', 40, true),
 ('126794dd-25ff-47d2-a436-724499733365', 'appointment_sold', 'Appointment Sold', 10.00, 0.10, 99,
  'An appointment you set and handed to someone else turned into a sale. $10 plus $0.10 for every one you already had sold this quarter (99 max). The money is yours, not the seller''s.', 50, true)
ON CONFLICT (agency_id, event_key) DO UPDATE
  SET label = EXCLUDED.label, base_points = EXCLUDED.base_points,
      step_per_prior = EXCLUDED.step_per_prior, prior_cap = EXCLUDED.prior_cap,
      description = EXCLUDED.description, sort_order = EXCLUDED.sort_order,
      is_active = true, updated_at = now();
