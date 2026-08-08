-- Peter directive 2026-08-08: drop six dead columns. Populated once (week ending 2026-06-20),
-- never defined, no consumer. The one week of values is preserved in persistent_memory
-- "Auto/Fire ratio + rank + bonus columns dropped from weekly_cpr_reports 2026-08-08".
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS auto_ratio_pct;
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS auto_rank;
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS auto_bonus;
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS fire_ratio_pct;
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS fire_rank;
ALTER TABLE public.weekly_cpr_reports DROP COLUMN IF EXISTS fire_bonus;
