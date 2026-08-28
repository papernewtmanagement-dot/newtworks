-- Cash Register Alert Ingestor was US Bank only in all three places that
-- matter: the Gmail search, the parse prompt, and the account label map.
-- American Express purchase alerts were never in scope, so they sat in the
-- inbox untouched. Amex alerts started arriving 2026-08-25.
-- This adds Amex alongside US Bank. US Bank behaviour is unchanged.

UPDATE automation_recipes
SET input_config = jsonb_set(
      input_config,
      '{gmail_query}',
      to_jsonb('{from:usbank@notifications.usbank.com from:AmericanExpress@welcome.americanexpress.com} newer_than:14d -label:Accounts-Alerts'::text)
    ),
    output_config = jsonb_set(
      output_config,
      '{account_labels}',
      (output_config->'account_labels')
        || jsonb_build_object(
             '1003', 'AMEX - Discretionary ...1003',
             '1006', 'AMEX Personal ...1006'
           )
    ),
    groq_prompt = $prompt$For EACH email in the input array, you MUST include a "source_message_id" field in your output record, set to the input message's "messageId" value verbatim. This is required for deduplication.

You are parsing bank and credit card alert emails from two senders: US Bank and American Express. Each sender has its own rules. Use the "from" field to decide which set applies.

======================= US BANK EMAILS =======================
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

=================== AMERICAN EXPRESS EMAILS ===================
Only completed purchase alerts are in scope — subject lines such as "Large Purchase Approved".

STEP 1 — find the account number printed after "Account Ending:". American Express prints it with extra leading digits, for example "Account Ending: 01003". Take the LAST 4 digits only, so 01003 becomes 1003.
The email may also name an "Additional Card ending" with a 6-digit number. That identifies which physical card was used, not the account. IGNORE it. Always report the account number from "Account Ending:".

STEP 2 — map that 4-digit number using THIS TABLE ONLY:
  credit_card  -> 1003, 1006
If the number is NOT in this table, DO NOT emit a record — it is not one of our accounts.

STEP 3 — emit one record per qualifying email:
- account_type: always "credit_card".
- account_last4: the 4-digit number from STEP 1.
- amount: the dollar figure printed with the merchant, as a number. Remove the dollar sign, any commas, and the trailing asterisk. "$123.34*" becomes 123.34
- direction: "debit" for a purchase. "credit" only when the email states the amount is a refund or a credit.
- merchant: the merchant name printed on the line directly above the amount, for example "SAMS CLUB" or "AMAZON MARKEPLACE NA PA". Copy it exactly as printed. Do not correct spelling and do not tidy spacing.
- txn_date: the transaction date printed just under the amount, for example "Tue, Aug 25, 2026" becomes 2026-08-25. Use that date, NOT the email Date header — the alert often arrives the following day.

DO NOT emit a record for an American Express email that is a payment received notice, a payment due or minimum payment notice, a statement ready notice, a fraud or security check, a rewards or offers message, or marketing. None of those are a purchase.

======================= BOTH SENDERS =======================
DO NOT emit a record for:
- declined-transaction alerts (subject or body says the transaction "was declined") — no money moved.
- balance alerts, security notices, marketing, statement-ready notices, or anything with no completed transaction amount.
- any account number outside the tables above.

Return strict JSON: {source_message_id, account_type, account_last4, amount, direction, merchant, txn_date}.$prompt$,
    updated_at = NOW()
WHERE id = '24628de9-e206-4dea-b51c-bc40721e404d';
