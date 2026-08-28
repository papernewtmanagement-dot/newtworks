-- Diagnosis: Composio returns Amex messageText as 61,700 characters of raw
-- HTML. automation-runner's extractGmailEssentials trusts messageText as-is
-- when it is present, so it never strips the tags -- it keeps the first 1,000
-- characters, which is the doctype and the stylesheet. The model never sees
-- the merchant, amount or account number, returns nothing, and
-- file_unparsed_messages then labels and archives a real transaction.
-- US Bank messageText is plain text, so US Bank has always worked.
--
-- The real fix is in the runner (strip HTML before capping). Until that is
-- deployed, pull Amex back out of the search so no further Amex alerts get
-- consumed and buried. US Bank ingestion continues untouched.

UPDATE automation_recipes
SET input_config = jsonb_set(
      input_config,
      '{gmail_query}',
      to_jsonb('from:usbank@notifications.usbank.com newer_than:14d -label:Accounts-Alerts'::text)
    ),
    updated_at = NOW()
WHERE id = '24628de9-e206-4dea-b51c-bc40721e404d';
