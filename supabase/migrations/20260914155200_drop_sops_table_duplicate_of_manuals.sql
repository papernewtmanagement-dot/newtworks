-- sops held 3 rows (Bookkeeping Process, Alvi - Personal Bookkeeping Process,
-- Payroll Process), all imported 2026-07-01 from the Confluence admin_pages
-- mirror and never edited since. Line-level diff 2026-09-14 confirmed every row
-- is superseded by a newer manuals row; no unique content. No frontend file,
-- edge function, or database function referenced the table. Peter approved the
-- drop 2026-09-14.
DROP TABLE IF EXISTS public.sops;
