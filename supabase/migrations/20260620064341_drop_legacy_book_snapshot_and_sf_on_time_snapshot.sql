-- Final stage of agency_snapshot cutover.
-- Data already replicated into public.agency_snapshot; all DB functions, views, and
-- the live frontend (commit 04b06579, Vercel deploy READY) read the new table.
-- Recipe 'Weekly Book Snapshot - Gmail Parse' output_table flipped earlier.
DROP TABLE public.book_snapshot;
DROP TABLE public.sf_on_time_snapshot;
