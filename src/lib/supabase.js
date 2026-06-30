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

// Business Entity ID — the legal entity scope for accounting/banking/payroll queries.
// Pairs with agency_id during the dual-scoped phase (see persistent_memory operational_rule
// "agency_id → business_entity_id refactor: phased plan").
// PaperNewt LLC:         b1111111-1111-1111-1111-111111111111
// Peter Story State Farm: b2222222-2222-2222-2222-222222222222 (default)
export const BUSINESS_ENTITY_ID = import.meta.env.VITE_BUSINESS_ENTITY_ID || 'b2222222-2222-2222-2222-222222222222'
