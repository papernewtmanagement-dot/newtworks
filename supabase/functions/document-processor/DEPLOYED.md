# document-processor deployment tracker

Authoritative record of what's currently deployed to the Supabase edge runtime.
The multi-file source in this directory is the intended source of truth, but
when the deployed bundle drifts from source (as during in-session inline
patches), record the drift here.

Retrieve the currently deployed body via first-party `Supabase:get_edge_function`
(Composio-relayed `SUPABASE_GET_FUNCTION_BODY` 413s on >~50KB bundles).

---

## v38 — 2026-07-08 21:48 UTC

- **status:** ACTIVE
- **ezbr_sha256:** `8619a4a08042775b8704f62ad959b80018b9113456271693713c611cb67bdb81`
- **verify_jwt:** `false` (pg_cron shared_secret path)
- **function_id:** `7a290145-b3b0-4391-b33c-60308254b9b2`
- **deployed via:** direct `Supabase:deploy_edge_function` MCP with inline single-file bundle

### Changes from v37

1. **QBO→COA account code migration.** All 15 `QBO-` account code references in the deployed bundle replaced with `COA-`. `chart_of_accounts` was renamed 2026-07-06 (commit 480479099b, corrected in c03497868) but the deployed bundle still carried the old prefix — latent bomb for next bank statement.
2. **Bug fix: us_bank_cc / 3447.** The `us bank cc | 3447` regex in `resolveSourceAccount` was mapped to `QBO-014`, which post-rename became `SF Card - Peter` (wrong). Corrected to `COA-025` (USBank GN Personal Card).

### Repo state

Multi-file source in `supabase/functions/document-processor/*.ts` still contains:
- COA codes (already correct — renamed 2026-07-06)
- **BUT missing:** SurePayroll parser section (`parsers/surepayroll.ts`), `surepayroll_payroll` DocType, index.ts case handler
- **BUT missing:** the 3447 bug fix (was QBO-014 in the repo too; may have been renamed to COA-014 during 2026-07-06 rename)

The deployed bundle is currently ahead of the repo source. Multi-file split task (in `docs/OPEN_QUESTIONS.md`) will bring the repo back in sync and regenerate the bundle via `scripts/bundle_document_processor.py`, then deploy as v39.

---

## v37 — 2026-07-07

SurePayroll classifier tightened to require .pdf extension.
Bundle mirror commit: `7fece22f` (call-log-parser build), `af07123d`.

