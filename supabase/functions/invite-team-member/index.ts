// =========================================================================
// invite-team-member  (BCC)
// =========================================================================
// PURPOSE: Invite a teammate to the BCC web app.
//   1. Verifies the caller is the agency owner (via their JWT)
//   2. Sends a Supabase Auth invite email (magic link -> set password)
//   3. Upserts a public.users row with role + allowed_modules
//
// AUTH:
//   verify_jwt = true  — the caller must be a logged-in BCC user. We further
//   require the caller's public.users row to have role 'owner' or 'manager'
//   for the same agency_id before allowing the invite.
//
// ENV (auto-provided by Supabase to every edge function):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY   — admin powers (inviteUserByEmail)
//   SUPABASE_ANON_KEY           — to validate the caller JWT
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: any, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // Admin client (service role) — used for the actual invite + db writes
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  try {
    // ── 1. Identify + authorize the caller from their JWT ──────────────
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace("Bearer ", "").trim();
    if (!token) return json({ error: "Missing Authorization bearer token" }, 401);

    const caller = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: who, error: whoErr } = await caller.auth.getUser();
    if (whoErr || !who?.user) return json({ error: "Invalid or expired session" }, 401);

    // Caller's BCC profile — must be owner/manager of the target agency
    const { data: callerRow, error: callerRowErr } = await admin
      .from("users")
      .select("id, agency_id, role")
      .eq("auth_user_id", who.user.id)
      .maybeSingle();
    if (callerRowErr) return json({ error: "Could not verify caller", detail: callerRowErr.message }, 500);
    if (!callerRow) return json({ error: "Caller has no BCC profile" }, 403);
    if (!["owner", "manager"].includes(callerRow.role)) {
      return json({ error: "Only an owner or manager can invite team members" }, 403);
    }

    // ── 2. Parse + validate the invite payload ─────────────────────────
    const body = await req.json().catch(() => ({}));
    const email = (body.email || "").trim().toLowerCase();
    const fullName = (body.full_name || body.name || "").trim();
    const role = (body.role || "staff").trim();
    // allowed_modules: array of module ids, or null for "all"
    let allowedModules: string[] | null = Array.isArray(body.allowed_modules)
      ? body.allowed_modules
      : null;
    if (role === "owner") allowedModules = null; // owners see everything

    if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
      return json({ error: "A valid email is required" }, 400);
    }
    if (!fullName) return json({ error: "Full name is required" }, 400);

    const agencyId = callerRow.agency_id;
    const redirectTo = body.redirect_to || "https://storybccdashboard.vercel.app/welcome";

    // ── 3. Send the Supabase Auth invite email ─────────────────────────
    // inviteUserByEmail creates an auth user (if new) and emails a magic link.
    const { data: invited, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(
      email,
      {
        redirectTo,
        data: { full_name: fullName, agency_id: agencyId, role },
      },
    );

    let authUserId: string | null = invited?.user?.id ?? null;

    // If the user already exists in auth, inviteUserByEmail errors. Recover by
    // finding the existing auth user so we can still (re)wire their profile.
    if (inviteErr && /already.*registered|already been registered|exists/i.test(inviteErr.message)) {
      const { data: list } = await admin.auth.admin.listUsers();
      const existing = list?.users?.find((u: any) => (u.email || "").toLowerCase() === email);
      authUserId = existing?.id ?? null;
      if (!authUserId) return json({ error: "User exists but could not be located", detail: inviteErr.message }, 500);
      // Re-send the invite/magic link so they can (re)set access
      await admin.auth.admin.generateLink({ type: "invite", email, options: { redirectTo } }).catch(() => {});
    } else if (inviteErr) {
      return json({ error: "Invite failed", detail: inviteErr.message }, 500);
    }

    // ── 4. Upsert the public.users profile row ─────────────────────────
    const profile: any = {
      agency_id: agencyId,
      email,
      full_name: fullName,
      role,
      allowed_modules: allowedModules,
      auth_user_id: authUserId,
      invited_by: callerRow.id,  // FK -> public.users.id (NOT auth uid)
      invited_at: new Date().toISOString(),
      is_active: true,
      invite_status: "invited",
      updated_at: new Date().toISOString(),
    };

    // Upsert on email within the agency (avoids dupes if re-invited)
    const { data: existingProfile } = await admin
      .from("users")
      .select("id")
      .eq("agency_id", agencyId)
      .eq("email", email)
      .maybeSingle();

    let upsertErr;
    if (existingProfile?.id) {
      ({ error: upsertErr } = await admin.from("users").update(profile).eq("id", existingProfile.id));
    } else {
      ({ error: upsertErr } = await admin.from("users").insert(profile));
    }
    if (upsertErr) return json({ error: "Invite email sent, but profile save failed", detail: upsertErr.message }, 500);

    return json({
      ok: true,
      message: `Invite email sent to ${email}`,
      auth_user_id: authUserId,
      email,
      role,
      allowed_modules: allowedModules,
    });
  } catch (e) {
    return json({ error: "Unexpected error", detail: String(e?.message || e) }, 500);
  }
});
