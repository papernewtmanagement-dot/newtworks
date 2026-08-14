-- Peter correction 2026-08-13: Google TV is PaperNewt waiting-room entertainment
-- on EVERY card. He never qualified it to certain cards; scoping it to the
-- PaperNewt AMEX was my assumption, not his instruction.
--
-- Removing the card scope and setting the target entity explicitly, so the rule
-- states the entity itself rather than inheriting it from whichever card paid.
UPDATE gl_classification_rules
SET match_source_account = NULL,
    target_business_entity_id = 'b1111111-1111-1111-1111-111111111111',
    updated_at = NOW(),
    override_reason = 'Peter correction 2026-08-13: applies to all cards, not just AMEX 2141. Card scope removed, target entity set to PaperNewt explicitly.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_name = 'Google TV — PaperNewt waiting-room entertainment';
