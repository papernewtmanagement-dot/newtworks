// =========================================================================
// _shared/auth.ts
// =========================================================================
// Canonical shared-secret gate for cron/internally-dispatched edge functions.
// The dispatch side (_dispatch_edge_fn, run_automation_recipe, automation-
// runner INTERNAL handlers) POSTs { agency_id, shared_secret } in the body;
// the secret must match settings.automation_runner_cron_secret.
//
// Usage in a handler:
//   const denied = await requireSharedSecret(agencyId, body.shared_secret);
//   if (denied) return denied;
// =========================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { getSettingOrNull, jsonResponse, corsJson, sb, SUPABASE_URL } from "./supabase.ts";

export async function requireSharedSecret(
  agencyId: string,
  provided: string | undefined | null,
): Promise<Response | null> {
  if (!provided) {
    return jsonResponse({ ok: false, error: "missing shared_secret" }, 401);
  }
  const expected = await getSettingOrNull(agencyId, "automation_runner_cron_secret");
  if (!expected || provided !== expected) {
    return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  }
  return null;
}

// -------------------------------------------------------------------------
// Caller-identity gate for admin actions fired from the browser
// -------------------------------------------------------------------------
// Some functions serve BOTH public token-gated traffic — which forces
// verify_jwt to stay false at the platform level — AND admin-only actions
// triggered from inside the Newtworks app. Those admin actions get no help
// from the platform gate, so they check the caller here instead: the bearer
// token has to identify a real signed-in user, and that user's public.users
// row has to be an owner or manager of the agency being acted on.
//
// Same two-step check invite-team-member does inline. This is the shared copy
// so the next function that needs it does not write a third one.
//
// A shared secret would NOT do the job here. The call comes from a browser,
// and anything the browser can send, anyone reading the page can read.

const ADMIN_ROLES = ["owner", "manager"];

export async function requireOwnerOrManager(
  req: Request,
  agencyId: string,
): Promise<Response | null> {
  const token = (req.headers.get("Authorization") || "").replace("Bearer ", "").trim();
  if (!token) return corsJson({ ok: false, error: "missing session token" }, 401);

  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!anonKey) return corsJson({ ok: false, error: "auth unavailable" }, 500);

  // The anon key is also what an unauthenticated caller sends as its bearer
  // token, so getUser() failing here is the normal "nobody is signed in" path,
  // not an infrastructure problem.
  const caller = createClient(SUPABASE_URL, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: who, error: whoErr } = await caller.auth.getUser();
  if (whoErr || !who?.user) return corsJson({ ok: false, error: "invalid or expired session" }, 401);

  const { data: row, error: rowErr } = await sb
    .from("users")
    .select("role, agency_id")
    .eq("auth_user_id", who.user.id)
    .maybeSingle();
  if (rowErr) return corsJson({ ok: false, error: "could not verify caller" }, 500);
  if (!row || row.agency_id !== agencyId || !ADMIN_ROLES.includes(row.role as string)) {
    return corsJson({ ok: false, error: "not permitted" }, 403);
  }
  return null;
}
