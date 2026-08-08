-- finrebuild_f5_drop_gl_entry_writer
-- Renamed to comp_gl_writer (3.2). Recipe "GL Entry Writer" repointed to
-- comp_gl_writer separately. No other DB function referenced gl_entry_writer
-- (checked via pg_get_functiondef sweep).
DROP FUNCTION IF EXISTS public.gl_entry_writer(uuid, boolean);
DROP FUNCTION IF EXISTS public.gl_entry_writer(uuid, uuid);