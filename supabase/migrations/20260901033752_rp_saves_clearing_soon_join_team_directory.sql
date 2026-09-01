-- The view runs with the caller's own permissions, and public.team only lets a
-- non-admin read their own row, so joining it blanked the name on everyone
-- else's saves. team_directory is the readable roster view the rest of the app
-- already uses for exactly this.
CREATE OR REPLACE VIEW public.rp_saves_clearing_soon
WITH (security_invoker = true) AS
SELECT l.id,
       l.agency_id,
       l.team_member_id,
       t.first_name,
       l.customer_label,
       l.save_line,
       l.save_reason,
       l.occurred_on,
       l.credit_available_on,
       l.credited_week_end_date,
       l.points,
       (l.credit_available_on - public.rp_today_central()) AS days_until_clear
FROM public.retention_activity_log l
LEFT JOIN public.team_directory t ON t.id = l.team_member_id
WHERE l.activity_key = 'cancellation_saved'
  AND l.status = 'credited'
  AND l.verified_at IS NULL
  AND l.credit_available_on IS NOT NULL
  AND l.credit_available_on >= public.rp_today_central();

GRANT SELECT ON public.rp_saves_clearing_soon TO authenticated;
