-- Records the FIX 11 entity-resolution decision so it survives outside this
-- session's conversation.
INSERT INTO persistent_memory (agency_id, category, title, content, source, updated_at, load_at_startup)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'accounting_rules',
  'Cash register posts use the bank account''s entity, not the register row''s',
  'The cash register writer resolves the business entity from the bank or card account, not from business_entity_id on the register row. Reason: all statement lines on accounts 3977, 4335 and 3447 are attributed to Peter Story State Farm, while some register rows arrive tagged PaperNewt LLC. Using the account keeps the entity stable when the statement later claims the row. Disagreements are reported as entity_mismatch in the writer summary rather than silently dropped.',
  'claude_conversation', NOW(), false);
