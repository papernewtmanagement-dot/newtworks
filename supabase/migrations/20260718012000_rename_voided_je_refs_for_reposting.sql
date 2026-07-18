-- Migration: rename_voided_je_refs_for_reposting
-- Applied 2026-07-18 via Supabase MCP.
-- Purpose: Voided JEs keep their unique reference_number, blocking fresh posts. Rename them
-- with -VOIDED-<8char> suffix so the fresh Plan A post can reuse the canonical reference.

UPDATE public.journal_entries
SET reference_number = reference_number || '-VOIDED-' || substring(id::text, 1, 8)
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND description LIKE '%[VOIDED %'
  AND reference_number NOT LIKE '%-VOIDED-%'
  AND reference_number NOT LIKE 'REVERSE-%';
