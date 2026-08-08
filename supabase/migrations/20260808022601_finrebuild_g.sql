-- finrebuild_f7_drop_retired_writers_and_suspense_fns
-- Phase 3.4: drop bank_gl_writer and cc_gl_writer (replaced by
-- statement_gl_writer; both recipe rows already repointed/deactivated).
-- Phase 3.5: drop check_suspense_aging and classify_je_via_chat — no
-- suspense account and no chat-classification path exist in the new
-- design (D3). Verified zero live callers (functions, edge functions,
-- automation recipes) before dropping.
DROP FUNCTION IF EXISTS public.bank_gl_writer(uuid, boolean);
DROP FUNCTION IF EXISTS public.bank_gl_writer(uuid, uuid);
DROP FUNCTION IF EXISTS public.cc_gl_writer(uuid, boolean);
DROP FUNCTION IF EXISTS public.cc_gl_writer(uuid, uuid);
DROP FUNCTION IF EXISTS public.check_suspense_aging(uuid);
DROP FUNCTION IF EXISTS public.classify_je_via_chat(uuid, uuid, text, text, text, boolean, text, integer, text, text, text, text, text);