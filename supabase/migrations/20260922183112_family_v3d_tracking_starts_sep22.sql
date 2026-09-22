-- Peter 2026-09-22: tracking starts today (Tue 2026-09-22) for every kid, Henry included.
UPDATE public.family_kids SET tracking_start = DATE '2026-09-22' WHERE tracking_start > DATE '2026-09-22';
UPDATE public.family_chores SET active_from = DATE '2026-09-22' WHERE active_from > DATE '2026-09-22';
