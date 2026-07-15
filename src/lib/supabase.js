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

// Business Entity ID — PaperNewt LLC is the S-Corp parent and the entity that
// consolidates ALL financial records (Story Agency P&L rolls into PaperNewt for
// S-Corp tax filing). Financials module + all entity-scoped queries filter on this.
// The individual entities:
//   PaperNewt LLC:          b1111111-1111-1111-1111-111111111111 (default — this)
//   Peter Story State Farm: b2222222-2222-2222-2222-222222222222 (operating DBA;
//                             remains meaningful for team.business_entity_id
//                             — which employee works for which entity —
//                             but NOT for financial records)
export const BUSINESS_ENTITY_ID = import.meta.env.VITE_BUSINESS_ENTITY_ID || 'b1111111-1111-1111-1111-111111111111'

// Legacy alias — same value as BUSINESS_ENTITY_ID now that the whole module
// is PaperNewt-scoped. Kept as an export for backward compatibility with any
// components still importing it; safe to remove in a future cleanup.
export const PAYROLL_ENTITY_ID = BUSINESS_ENTITY_ID
