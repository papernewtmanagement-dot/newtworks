-- Drop the backward-compat view for public.playbook.
-- All callers now point at public.processes:
--   * frontend (src/modules/Processes.jsx): commit 4ef1e938
--   * edge functions: invite-team-member v4, terminate-team-member v2, chatbot v5
DROP VIEW IF EXISTS public.playbook;
