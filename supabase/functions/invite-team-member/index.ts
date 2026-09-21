// =========================================================================
// invite-team-member
// =========================================================================
// PURPOSE: Send a teammate their Newtworks login invite.
//   1. Confirms who is asking (see AUTH below)
//   2. Sends a Supabase Auth invite email (magic link -> set password)
//   3. Upserts the public.users row (role defaults to staff)
//   4. Links that users row to the team row and clears team.login_invite_due
//
// TWO CALLERS, ONE FUNCTION:
//   a) Add Member form in Team.jsx — an owner/manager, signed in, clicking
//      "Save & Invite" for someone starting today or earlier.
//   b) public.send_due_login_invites() on the hourly tick — a hire added
//      before their start date, invited from 7 a.m. Central on that date.
//      Body: { scheduled: true, shared_secret, team_member_id }. Name, email
//      and agency are read from the team row, not the request.
//
// AUTH:
//   verify_jwt = true. Form calls must come from a users row with role
//   owner or manager. Scheduled calls must carry the service-role bearer
//   and the automation_runner_cron_secret setting.
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const DEFAULT_REDIRECT = "https://storybccdashboard.vercel.app/welcome";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// Raise one open alert per team member when a scheduled invite fails.
// The hourly tick keeps retrying; this just makes sure Peter hears about it.
async function alertScheduledFailure(agencyId: string, teamId: string, name: string, detail: string) {
  const { data: open } = await admin
    .from("alerts")
    .select("id")
    .eq("agency_id", agencyId)
    .eq("alert_type", "login_invite_failed")
    .eq("related_id", teamId)
    .eq("is_resolved", false)
    .limit(1);
  if (Array.isArray(open) && open.length > 0) return;
  await admin.from("alerts").insert({
    agency_id: agencyId,
    alert_type: "login_invite_failed",
    severity: "warning",
    title: `Login invite did not send for ${name}`,
    message: `The start-day login invite failed and will retry every hour. Reason: ${detail}`,
    module_reference: "team",
    related_id: teamId,
    is_read: false,
    is_resolved: false,
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let scheduledCtx: { agencyId: string; teamId: string; name: string } | null = null;

  try {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "").trim();
    if (!token) return json({ error: "Missing Authorization bearer token" }, 401);
    const body = await req.json().catch(() => null) as any;
    if (!body) return json({ error: "JSON body required" }, 400);

    let agencyId: string;
    let invitedBy: string | null;
    let email: string;
    let fullName: string;
    let role = "staff";
    let teamMemberId: string | null = body.team_member_id ? String(body.team_member_id) : null;

    if (body.scheduled === true) {
      // ---- Scheduled path (hourly tick) -----------------------------------
      if (token !== SERVICE_ROLE_KEY) return json({ error: "Scheduled calls need the service key" }, 401);
      if (!teamMemberId) return json({ error: "team_member_id required" }, 400);

      const { data: t, error: tErr } = await admin
        .from("team")
        .select("id, agency_id, first_name, last_name, email_personal, login_invite_due, archived_at")
        .eq("id", teamMemberId)
        .maybeSingle();
      if (tErr || !t) return json({ error: "team row not found" }, 404);

      const { data: secretRow } = await admin
        .from("settings")
        .select("setting_value")
        .eq("agency_id", t.agency_id)
        .eq("setting_key", "automation_runner_cron_secret")
        .maybeSingle();
      if (!secretRow?.setting_value || body.shared_secret !== secretRow.setting_value) {
        return json({ error: "Bad shared secret" }, 401);
      }

      // Already sent (or cancelled) since the tick picked it up: nothing to do.
      if (!t.login_invite_due || t.archived_at) return json({ ok: true, skipped: "no invite waiting" });
      if (!t.email_personal) return json({ error: "No personal email on file" }, 400);

      agencyId = t.agency_id;
      email = String(t.email_personal).trim().toLowerCase();
      fullName = `${t.first_name || ""} ${t.last_name || ""}`.trim();
      scheduledCtx = { agencyId, teamId: t.id, name: fullName || email };

      const { data: owner } = await admin
        .from("users")
        .select("id")
        .eq("agency_id", agencyId)
        .eq("role", "owner")
        .order("created_at", { ascending: true })
        .limit(1)
        .maybeSingle();
      invitedBy = owner?.id || null;
    } else {
      // ---- Form path (signed-in owner or manager) --------------------------
      const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
        global: { headers: { Authorization: `Bearer ${token}` } },
      });
      const { data: userInfo, error: userErr } = await callerClient.auth.getUser();
      if (userErr || !userInfo?.user) return json({ error: "Invalid session" }, 401);

      const { data: callerRow, error: callerErr } = await admin
        .from("users")
        .select("id, role, agency_id")
        .eq("auth_user_id", userInfo.user.id)
        .maybeSingle();
      if (callerErr || !callerRow) return json({ error: "Caller has no users row" }, 403);
      if (!callerRow.agency_id) return json({ error: "Caller has no agency" }, 403);
      if (callerRow.role !== "owner" && callerRow.role !== "manager") {
        return json({ error: "Only agency owners and managers can invite teammates" }, 403);
      }
      if (!body.email || !body.full_name) return json({ error: "email and full_name required" }, 400);

      agencyId = callerRow.agency_id;
      invitedBy = callerRow.id;
      email = String(body.email).trim().toLowerCase();
      fullName = String(body.full_name).trim();
      role = String(body.role || "staff").trim();
      if (!["owner", "manager", "staff", "readonly", "accountant"].includes(role)) {
        return json({ error: `Invalid role: ${role}` }, 400);
      }
    }

    // ---- Send the invite (or a magic link if the email already exists) ------
    const redirectTo = body.redirect_to || DEFAULT_REDIRECT;
    const meta = { full_name: fullName, invited_by: invitedBy };
    const { data: inviteData, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo,
      data: meta,
    });

    let authUserId: string | null = inviteData?.user?.id || null;
    let fallbackUsed = false;
    if (inviteErr) {
      const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({
        type: "magiclink",
        email,
        options: { redirectTo, data: meta },
      });
      if (linkErr) {
        const detail = `Auth invite failed: ${inviteErr.message}; link fallback failed: ${linkErr.message}`;
        if (scheduledCtx) await alertScheduledFailure(scheduledCtx.agencyId, scheduledCtx.teamId, scheduledCtx.name, detail);
        return json({ error: detail }, 500);
      }
      authUserId = linkData?.user?.id || null;
      fallbackUsed = true;
    }
    if (!authUserId) {
      if (scheduledCtx) await alertScheduledFailure(scheduledCtx.agencyId, scheduledCtx.teamId, scheduledCtx.name, "No auth user id returned");
      return json({ error: "No auth user id returned from Supabase Auth" }, 500);
    }

    // ---- Upsert public.users -------------------------------------------------
    const upsertPayload: Record<string, unknown> = {
      auth_user_id: authUserId,
      email,
      full_name: fullName,
      role,
      agency_id: agencyId,
      invite_status: "invited",
      is_active: true,
      invited_by: invitedBy,
      invited_at: new Date().toISOString(),
    };
    if (teamMemberId) upsertPayload.team_member_id = teamMemberId;
    if (body.phone) upsertPayload.phone = String(body.phone).trim();
    if (body.notes) upsertPayload.notes = String(body.notes).trim();

    const { data: pubUser, error: upsertErr } = await admin
      .from("users")
      .upsert(upsertPayload, { onConflict: "auth_user_id" })
      .select()
      .maybeSingle();
    if (upsertErr) {
      if (scheduledCtx) await alertScheduledFailure(scheduledCtx.agencyId, scheduledCtx.teamId, scheduledCtx.name, upsertErr.message);
      return json({ error: `Failed to upsert public.users: ${upsertErr.message}` }, 500);
    }

    // ---- Nothing is waiting any more for this team row ------------------------
    if (teamMemberId) {
      await admin.from("team").update({ login_invite_due: null }).eq("id", teamMemberId).eq("agency_id", agencyId);
    }

    return json({
      ok: true,
      user: pubUser,
      invite_fallback_used: fallbackUsed,
      message: fallbackUsed ? "Existing user — sent a magic link instead of a new invite." : "Invite email sent.",
    });
  } catch (e: any) {
    const detail = e?.message || String(e);
    if (scheduledCtx) await alertScheduledFailure(scheduledCtx.agencyId, scheduledCtx.teamId, scheduledCtx.name, detail).catch(() => {});
    return json({ error: `Uncaught: ${detail}` }, 500);
  }
});
