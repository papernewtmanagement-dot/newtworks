# Newtworks Schema Normalization Runbook
## For existing-client installs (Process A)

This is the playbook that turns a 20-hour custom schema-bridging slog into a 30-minute audit-and-bridge cycle.

## When to use
Any client whose Supabase was built BEFORE the Newtworks web app schema. That's all installs except brand-new ones.

## What it does
The web app expects 37 specific tables with specific column names (defined in `001_bcc_master_schema.sql`). Existing clients have those concepts under different table/column names. Instead of editing 11 React modules to match each client, we create database VIEWS that present each legacy table under the master name. The web app sees what it expects. Real data stays untouched.

---

## Step 1 — Run the audit
Open Supabase Studio for the client, paste `bcc_schema_audit.sql`, run it.

You get back ~40 rows in three sections:
- **TABLE AUDIT** (37 rows) — one per master table. Status = `ok` / `bridge_needed` / `missing`
- **VIEW AUDIT** (2 rows) — `v_income_statement` and `v_balance_sheet`
- **ANON ACCESS** (1 row) — does the anon role have grants

**Read the result like this:**
- `ok` → nothing to do
- `bridge_needed` → legacy table exists, the `legacy_name` column tells you what to alias
- `missing` (with empty `legacy_name`) → genuinely missing, run the corresponding migration
- `missing — apply migration 006` → run `006_derived_financial_views.sql`
- `missing — apply migration 005` → run `005_anon_read_policies.sql`

## Step 2 — Apply migrations for missing pieces
For everything in section 1 with status `missing` AND no legacy_name, the relevant CREATE TABLE is in `001_bcc_master_schema.sql`. Either:
- Run all of 001 (it's `IF NOT EXISTS` safe — won't touch existing tables), OR
- Cherry-pick the CREATE TABLE blocks for the missing tables only

For section 2 missing → run migration 006.
For section 3 missing → run migration 005.

**Also required for every install (Path A and Path B):**
- `monthly_close_checklist` table missing → run migration 007.
- `producer_production` table missing OR `agency.smvc_rate_pc` column missing → run migration 010 (Producer ROI infrastructure). The HR & People → Performance tab depends on this. After migration 010, ask the agent for their A005 SMVC rate and update the agency record:
```sql
UPDATE agency
SET smvc_rate_pc = 10.00,        -- their actual P&C SMVC rate
    blended_rate_other = 9.00,   -- their actual blended rate for other lines
    lapse_rate_annual = NULL     -- NULL = compute from comp_recap
WHERE id = (SELECT id FROM agency LIMIT 1);
```

## Step 3 — Install the bridge generator
Paste `supabase/migrations/008_bridge_generator.sql` and run it. This installs a function. It does not create views yet.

## Step 4 — Generate bridge SQL
Build a JSON map of every `bridge_needed` row from the audit, in the form `{"legacy_name":"master_name", ...}`. Then:

```sql
SELECT * FROM bcc_generate_bridges('{
  "employees":"staff",
  "agencies":"agency",
  "recipes":"automation_recipes"
}'::jsonb);
```

You get back one row per pair with:
- `bridge_sql` — a ready-to-run `CREATE OR REPLACE VIEW` statement
- `matched_cols` / `unmapped_master_cols` — so you can see what was mapped vs filled with NULL

## Step 5 — Review and apply bridges
Read each `bridge_sql`. Unmapped columns become `NULL` casts of the right type — that's correct: the web app gets the column it expects, even if the legacy data doesn't have it. **Critical: don't reach for the legacy table to "rename a column" — leave the legacy table alone, the view does the translation.**

If a bridge has too many unmapped columns to be useful (e.g., 18 master cols, 3 matched), that's a sign the legacy table isn't actually equivalent — flag it for manual review rather than building a useless view.

Copy each `bridge_sql` into Studio, run them.

## Step 6 — Re-run the audit
Section 1 should now be all `ok` (the views satisfy the existence check). If anything is still `bridge_needed`, you missed it in Step 4.

## Step 7 — Smoke test in browser
Per CLAUDE.md: dashboard agency name, Financials > GL, HR > Add Employee form. Same checks as before. Any module that crashes now is a column-level mismatch the bridge didn't catch — fix that one view, not the React code.

---

## Hard rules
- **Never DROP, ALTER, or RENAME a legacy table.** Views only.
- **Never delete legacy data.** Views are read-through; the table underneath stays as-is.
- **One bridge view per master table.** If the legacy schema split a master concept across two tables, build a UNION view manually.
- **If you can't bridge it cleanly, log it and move on.** Module will show EmptyState. That's correct, not broken.

## What this replaces
Days of editing module JSX files to match each client's schema. Don't do that anymore. The React code is the contract; the database conforms via views.
