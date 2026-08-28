-- First Amex run failed: Groq HTTP 413, request 9164 tokens against an
-- 8000 tokens-per-minute ceiling. Amex alert emails are far bulkier than
-- US Bank ones, and the runner sends every fetched message to the model in
-- a single call. Two levers, both recipe config, no code change:
--   1. max_results 10 -> 3, so each run sends at most three emails.
--   2. prompt tightened (US Bank rules kept word for word).
-- Three per hour is 72/day against roughly five Amex alerts a day.

UPDATE automation_recipes
SET input_config = jsonb_set(input_config, '{max_results}', '3'::jsonb),
    groq_prompt = $prompt$For EACH email in the input array, you MUST include a "source_message_id" field in your output record, set to the input message's "messageId" value verbatim. This is required for deduplication.

You are parsing alert emails from two senders: US Bank and American Express. Use the "from" field to pick which rules apply.

=== US BANK ===
ALL US Bank accounts are in scope — business AND personal.

STEP 1 — find the 4-digit account number. It appears after "account ending in", "card ending in", or "business card ending in".

STEP 2 — map that number to account_type using THIS TABLE ONLY:
  checking     -> 0353, 2545, 3977, 4335, 6730, 6755
  credit_card  -> 3447, 4676, 3439, 8847
If the number is NOT in this table, DO NOT emit a record — it is not one of our accounts.

STEP 3 — emit one record per qualifying email:
- account_type: from the table above. Derive it from the NUMBER, never from the subject line.
- account_last4: the 4-digit number exactly as it appeared in the email. Do not translate 4676 or 3439 into 3447; emit what the email said.
- amount: the dollar figure as a number, no $ and no commas.
- direction:
    checking    -> "credit" if the body says "Your deposit of", otherwise "debit" (body says "Your transaction of").
    credit_card -> "debit" when the body says the card "was charged"; "credit" when the email is a posted credit or refund (e.g. "Credit posted").
- merchant: for credit_card charges only, the text between "was charged $AMOUNT at" and " . A purchase was made". NULL for everything else, including all checking transactions.
- txn_date: the email Date header, formatted YYYY-MM-DD.

=== AMERICAN EXPRESS ===
Only completed purchase alerts are in scope, such as "Large Purchase Approved". Emit NOTHING for a payment received, payment due, statement ready, fraud check, rewards, or marketing email.

STEP 1 — take the number after "Account Ending:" and keep only its LAST 4 digits (01003 -> 1003). If the email also names an "Additional Card ending" number, IGNORE it — that is the physical card, not the account.

STEP 2 — map that 4-digit number using THIS TABLE ONLY:
  credit_card  -> 1003, 1006
If the number is NOT in this table, DO NOT emit a record.

STEP 3 — emit one record per qualifying email:
- account_type: always "credit_card".
- account_last4: the number from STEP 1.
- amount: the figure printed with the merchant, as a number, with the dollar sign, commas and trailing asterisk removed. "$123.34*" -> 123.34
- direction: "debit" for a purchase; "credit" only if the email says it is a refund or credit.
- merchant: the merchant name on the line directly above the amount, e.g. "SAMS CLUB". Copy it exactly as printed — do not fix spelling or spacing.
- txn_date: the date printed under the amount, e.g. "Tue, Aug 25, 2026" -> 2026-08-25. Use that, NOT the email Date header — the alert often arrives the next day.

=== BOTH ===
DO NOT emit a record for:
- declined-transaction alerts (subject or body says the transaction "was declined") — no money moved.
- balance alerts, security notices, marketing, statement-ready notices, or anything with no completed transaction amount.
- any account number outside the tables above.

Return strict JSON: {source_message_id, account_type, account_last4, amount, direction, merchant, txn_date}.$prompt$,
    updated_at = NOW()
WHERE id = '24628de9-e206-4dea-b51c-bc40721e404d';
