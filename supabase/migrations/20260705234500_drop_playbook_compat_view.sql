-- Drop the backward-compat view for public.playbook.
-- All callers now point at public.processes:
--   * frontend (src/modules/Processes.jsx): commit 4ef1e938
--   * edge functions: invite-team-member v4, terminate-team-member v2, chatbot v5
-- The view was created in migration 20260705231500_playbook_to_processes_rename.sql
-- as a transition safety-net; every caller has since been migrated + verified.
DROP VIEW IF EXISTS public.playbook;
