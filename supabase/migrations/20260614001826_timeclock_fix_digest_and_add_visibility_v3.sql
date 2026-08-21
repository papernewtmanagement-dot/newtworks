CREATE OR REPLACE FUNCTION public.time_clock_hash_pin(p_agency_id uuid, p_pin text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT encode(extensions.digest(p_agency_id::text || ':' || p_pin, 'sha256'), 'hex');
$$;

ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS is_test_user boolean NOT NULL DEFAULT false;

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS team_member_id uuid
    REFERENCES public.team(id) ON DELETE SET NULL;

CREATE OR REPLACE VIEW public.v_time_clock_status AS
SELECT t.id AS team_member_id,
       t.agency_id,
       t.first_name,
       t.last_name,
       t.pay_rate,
       (t.time_clock_pin_hash IS NOT NULL) AS pin_set,
       e.id AS open_entry_id,
       e.clock_in_at,
       (e.id IS NOT NULL) AS is_clocked_in,
       CASE
         WHEN e.clock_in_at IS NULL THEN NULL::numeric
         ELSE round(EXTRACT(epoch FROM now() - e.clock_in_at) / 3600.0, 2)
       END AS hours_this_block,
       t.is_test_user
FROM team t
LEFT JOIN time_clock_entries e
  ON e.team_member_id = t.id AND e.clock_out_at IS NULL
WHERE t.is_active = true
  AND t.pay_type = 'HOURLY'::text
  AND t.archived_at IS NULL;

INSERT INTO public.team (
  agency_id, first_name, last_name, role, employment_type,
  pay_type, pay_rate, is_active, hire_date, is_test_user,
  notes
)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Test', 'User', 'Reception', 'Full Time',
  'HOURLY', 15.00, true, CURRENT_DATE, true,
  'Owner-only visibility test row. Use to verify TimeClock punch loop. Do not include in payroll reports.'
);
