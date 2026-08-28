-- automation-runner v55 now converts HTML email bodies to plain text before
-- the per-message character cap, so American Express alerts are readable by
-- the parser. Put Amex back into the ingestor's search.
-- Pairs with commit 324274e15c36a7ad37bdfb3dd623a8be27a29daa.

UPDATE automation_recipes
SET input_config = jsonb_set(
      input_config,
      '{gmail_query}',
      to_jsonb('{from:usbank@notifications.usbank.com from:AmericanExpress@welcome.americanexpress.com} newer_than:14d -label:Accounts-Alerts'::text)
    ),
    updated_at = NOW()
WHERE id = '24628de9-e206-4dea-b51c-bc40721e404d';
