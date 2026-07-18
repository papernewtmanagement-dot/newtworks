import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  console.error('Missing VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY environment variables. Check your .env file or Vercel environment settings.')
}

// Null guard — supabase will be null if env vars are missing
// All modules must guard against null supabase before calling .from()
export const supabase = (supabaseUrl && supabaseAnonKey)
  ? createClient(supabaseUrl, supabaseAnonKey)
  : null

// Agency ID — set this to your Supabase agency row ID after running migration 004
// Find it with: SELECT id FROM agency LIMIT 1;
export const AGENCY_ID = import.meta.env.VITE_AGENCY_ID || null

// PaperNewt LLC entity UUID — the S-Corp parent. Exported under two names for
// callers to pick the one that reads best at the call site:
//   PAPERNEWT_ENTITY_ID — canonical. Use when the intent is "PaperNewt specifically."
//   BUSINESS_ENTITY_ID  — legacy alias. Same value. Kept so pre-hierarchy callers
//                         still compile; new code should prefer PAPERNEWT_ENTITY_ID.
//
// Entity hierarchy context (post-Phase-3, 2026-07-17):
//   Financials module now drives off an entity URL param via useTabParam("entity")
//   rooted at Peter Story (personal, b3333333) and recurses through:
//     Peter Story (personal, root, b3333333)
//       └── PaperNewt LLC (s_corp, b1111111)
//           ├── Peter Story State Farm (sole_prop, b2222222)
//           ├── Story Business Administration (sole_prop, b4444444)
//           └── Eriosto (llc, b5555555)
//   P&L / Bank / Credit / Balance Sheet / GL sections all filter to the current
//   entity's subtree (Option B flat listing for Bank/Credit/BS/GL; one-line
//   consolidation for P&L). None of those code paths use BUSINESS_ENTITY_ID —
//   they read entity from the URL param + descendantsOf(currentEntity).
//
// Where the constant is STILL used (design-intent hardcodes, not audit gaps):
//   - payroll_runs / payroll_detail fetches (Financials + Team modules).
//     PaperNewt is the S-Corp employer of record per the two-entity payroll
//     convention (see core_principles financial_health rule "two_entity_payroll").
//   - CashRegister module (bank register + starting balances). Module is
//     inherently PaperNewt-scoped for now.
//
// A row this constant is inserted into does NOT need to also live under
// tg_default_business_entity_from_agency's PaperNewt fallback — the trigger
// only fires when business_entity_id is NULL at INSERT time; explicit sets
// bypass it. The trigger is the ultimate safety net for anything that forgets
// to set the entity_id at all.
export const PAPERNEWT_ENTITY_ID = import.meta.env.VITE_BUSINESS_ENTITY_ID || 'b1111111-1111-1111-1111-111111111111'
export const BUSINESS_ENTITY_ID  = PAPERNEWT_ENTITY_ID
export const PAYROLL_ENTITY_ID   = PAPERNEWT_ENTITY_ID
