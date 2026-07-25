-- Capture the RFC-2822 Message-Id header on every CPR RECAP send so that
-- teammate replies (In-Reply-To carries the RFC id, NOT Gmail's internal id)
-- can be routed back to the correct week by wrapup_ingest.

CREATE OR REPLACE FUNCTION public.extract_rfc_message_id(p_content jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(h->>'value', '<>')
    FROM jsonb_array_elements(p_content #> '{data,payload,headers}') h
   WHERE lower(h->>'name') = 'message-id'
   LIMIT 1;
$$;

-- Update verify_pending_cpr_sends Phase 2 confirmed-sent branch to also
-- write cpr_recap_message_id_rfc. Rest of function preserved verbatim.
-- (Full body applied via Supabase MCP migration; this file is the mirror.)
