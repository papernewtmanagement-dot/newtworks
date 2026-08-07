-- jp_public_active and jsq_public_active both target role authenticated only
-- (verified via polroles directly), never anon. They were left alone earlier
-- under the wrong assumption they were the public careers-page read path --
-- confirmed by code inspection that the actual public page reads through
-- careers-site's new service-role JSON routes, not through these policies at
-- all. So these two only ever served signed-in staff a permissive-OR leak
-- around job_postings_admin_read / job_screener_questions_admin_read.
-- Published+active postings are meant to be public anyway, so this was low
-- severity, but it's still an unintended extra grant. Closing it.
DROP POLICY jp_public_active ON public.job_postings;
DROP POLICY jsq_public_active ON public.job_screener_questions;
