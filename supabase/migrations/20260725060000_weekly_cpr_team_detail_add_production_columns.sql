-- Add nine per-teammate per-week production columns to weekly_cpr_team_detail.
-- Source: State Farm Digital Whiteboard Office Report (Sunday-Saturday, Applications tab).
-- Coaching/analysis only. NOT read by any compute writer (pool math untouched).
-- All nullable, default NULL. Historical rows stay clean.

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS prod_total_count    integer,
  ADD COLUMN IF NOT EXISTS prod_total_premium  numeric,
  ADD COLUMN IF NOT EXISTS prod_issued_count   integer,
  ADD COLUMN IF NOT EXISTS prod_issued_premium numeric,
  ADD COLUMN IF NOT EXISTS prod_auto           integer,
  ADD COLUMN IF NOT EXISTS prod_fire           integer,
  ADD COLUMN IF NOT EXISTS prod_life           integer,
  ADD COLUMN IF NOT EXISTS prod_health         integer,
  ADD COLUMN IF NOT EXISTS prod_bank           integer;

COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_total_count    IS 'State Farm Digital Whiteboard Office Report: Total Applications count for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_total_premium  IS 'State Farm Digital Whiteboard Office Report: Total Applications premium for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_issued_count   IS 'State Farm Digital Whiteboard Office Report: Issued Applications count for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_issued_premium IS 'State Farm Digital Whiteboard Office Report: Issued Applications premium for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_auto            IS 'State Farm Digital Whiteboard Office Report: Auto item count for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_fire            IS 'State Farm Digital Whiteboard Office Report: Fire item count for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_life            IS 'State Farm Digital Whiteboard Office Report: Life item count for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_health          IS 'State Farm Digital Whiteboard Office Report: Health item count for the week.';
COMMENT ON COLUMN public.weekly_cpr_team_detail.prod_bank             IS 'State Farm Digital Whiteboard Office Report: Bank item count for the week.';
