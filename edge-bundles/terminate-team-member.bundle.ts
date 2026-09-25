// =========================================================================
// terminate-team-member bundle (auto-generated)
// Source of truth: supabase/functions/terminate-team-member/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py terminate-team-member`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// ==================== _shared/supabase.ts ====================
// =========================================================================
// _shared/supabase.ts
// =========================================================================
// Canonical Supabase client + settings + response helpers for ALL Newtworks
// edge functions. Source of truth for code that used to be copy-pasted into
// every function (client creation, getSetting, jsonResponse, stripFences).
//
// Edge functions deploy as single-file bundles: `scripts/bundle_edge_fn.py`
// inlines this file into each function's bundle. Never edit a bundle by hand;
// edit here and rebundle every consumer.
// =========================================================================


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Service role — bypasses RLS. Same client options every function used.
const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Single-agency install. Functions that accept agency_id in the request body
// should still prefer the body value; this is the fallback.
const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

// -------------------------------------------------------------------------
// Settings
// -------------------------------------------------------------------------
// Two variants on purpose — they preserve the two behaviors that existed in
// the wild before consolidation:
//   getSetting        — THROWS if the settings table read itself errors
//                       (infra failure ≠ missing row). Use on critical paths.
//   getSettingOrNull  — swallows read errors, returns null. Use where the
//                       caller treats "can't read" the same as "not set".
// Both return null when the row simply doesn't exist.
// -------------------------------------------------------------------------

async function getSetting(
  agencyId: string,
  key: string,
): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) {
    throw new Error(
      `settings read failed for agency ${agencyId} key ${key}: ${error.message}`,
    );
  }
  return data?.setting_value ?? null;
}

async function getSettingOrNull(
  agencyId: string,
  key: string,
): Promise<string | null> {
  try {
    const { data } = await sb
      .from("settings")
      .select("setting_value")
      .eq("agency_id", agencyId)
      .eq("setting_key", key)
      .maybeSingle();
    return (data?.setting_value as string | null) ?? null;
  } catch (_e) {
    return null;
  }
}

// Batch read — one query for N keys. Missing keys come back as null.
async function getSettings(
  agencyId: string,
  keys: string[],
): Promise<Record<string, string | null>> {
  const out: Record<string, string | null> = {};
  for (const k of keys) out[k] = null;
  const { data, error } = await sb
    .from("settings")
    .select("setting_key,setting_value")
    .eq("agency_id", agencyId)
    .in("setting_key", keys);
  if (error) {
    throw new Error(`settings batch read failed for agency ${agencyId}: ${error.message}`);
  }
  for (const row of data ?? []) {
    out[(row as any).setting_key] = (row as any).setting_value ?? null;
  }
  return out;
}

// -------------------------------------------------------------------------
// HTTP responses
// -------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// -------------------------------------------------------------------------
// Text helpers
// -------------------------------------------------------------------------

// Strip ```json fences an LLM wrapped around its output.
function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
}

// ==================== _shared/watchers.ts ====================
// =========================================================================
// _shared/watchers.ts
// =========================================================================
// Canonical "something needs a human" writer for ALL Newtworks edge
// functions. Replaces the retired _shared/alerts.ts.
//
// Why this exists: the alerts table was retired 2026-09-16 because nothing
// read it. A condition that genuinely needs Peter to act now becomes an
// ordinary row in tasks, so it gets scored, gets hours, and lands in a week
// like every other piece of work. Both helpers wrap the SQL functions
// ensure_watcher_task / close_watcher_task so the shaping lives in exactly
// one place, database side and edge side alike.
//
// Dedupe is on created_by ('watcher:' || source) plus related_id, open rows
// only. related_id must be a uuid or null. When the thing repeats per period
// and has no uuid of its own, PUT THE PERIOD IN THE SOURCE STRING
// (e.g. "wrapup_parser_stuck:2026-09-12") and leave relatedId null.
// =========================================================================


// tasks_priority_check allows exactly these four. "urgent" is NOT one of them.
type WatcherPriority = "low" | "medium" | "high" | "critical";

// tasks.task_category is a fixed check-constrained list. Anything outside it
// fails the insert.
type WatcherCategory =
  | "web_app"
  | "admin"
  | "marketing"
  | "team_development"
  | "handbook"
  | "processes"
  | "finances";

async function ensureWatcherTask(opts: {
  agencyId: string;
  source: string;
  relatedId?: string | null;
  title: string;
  description: string;
  priority?: WatcherPriority;
  category?: WatcherCategory;
}): Promise<{ ok: boolean; created: boolean; error: string | null }> {
  const { data, error } = await sb.rpc("ensure_watcher_task", {
    p_agency_id: opts.agencyId,
    p_source: opts.source,
    p_related_id: opts.relatedId ?? null,
    p_title: opts.title,
    p_description: opts.description,
    p_priority: opts.priority ?? "medium",
    p_category: opts.category ?? "admin",
  });
  if (error) {
    // Never throw — reporting a problem must not mask the problem being
    // reported. Surface the miss to whoever reads the function logs.
    console.error(`ensureWatcherTask failed (${opts.source}): ${error.message}`);
    return { ok: false, created: false, error: error.message };
  }
  return { ok: true, created: data === true, error: null };
}

async function closeWatcherTask(opts: {
  agencyId: string;
  source: string;
  relatedId?: string | null;
}): Promise<{ ok: boolean; closed: boolean; error: string | null }> {
  const { data, error } = await sb.rpc("close_watcher_task", {
    p_agency_id: opts.agencyId,
    p_source: opts.source,
    p_related_id: opts.relatedId ?? null,
  });
  if (error) {
    console.error(`closeWatcherTask failed (${opts.source}): ${error.message}`);
    return { ok: false, closed: false, error: error.message };
  }
  return { ok: true, closed: data === true, error: null };
}

// ==================== _shared/auth.ts ====================
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


async function requireSharedSecret(
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

const ADMIN_ROLES = ["owner", "admin"];

async function requireOwnerOrManager(
  req: Request,
  agencyId: string,
): Promise<Response | null> {
  return requireCallerRole(req, agencyId, ADMIN_ROLES);
}

// Owner only. Terminations use this. Peter 2026-09-25: "A termination should
// only come from me through the website."
async function requireOwner(
  req: Request,
  agencyId: string,
): Promise<Response | null> {
  return requireCallerRole(req, agencyId, ["owner"]);
}

// The one caller check. The wrappers above only choose which roles pass.
async function requireCallerRole(
  req: Request,
  agencyId: string,
  roles: string[],
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
  if (!row || row.agency_id !== agencyId || !roles.includes(row.role as string)) {
    return corsJson({ ok: false, error: "not permitted" }, 403);
  }
  return null;
}

// ==================== terminate-team-member/index.ts ====================
// terminate-team-member edge function (v2)
//
// Orchestrates a State Farm team-member termination:
//   0. Refuses anyone but the owner's own login (Peter 2026-09-25).
//   1. Loads the team member + the termination checklist (Team → Termination
//      tab, public.termination_checklist).
//   2. Composes an HTML notification email with identity, contact (incl. physical
//      address), SF identifiers (alias + ext), and the verbatim AAO checklist
//      pre-filled with name/alias/extension.
//   3. Updates team: archived_at, end_date, is_active=false, termination_reason,
//      final_paycheck_date.
//   4. Deactivates the linked users row if present.
//   5. Blocks them from both Telegram bots (team.is_excluded_pjsagencybot and
//      team.is_excluded_paper_newt_bot) in the same update as step 3. Until
//      2026-09-25 this wrote to team_telegram_map, a table that no longer
//      exists, so it never took.
//   6. Strips the person's block from the "Team List" processes page.
//   7. Takes the person off every team meeting invite (Daily Kickoff, Coffee
//      and Donuts, Daily Wrap-up) straight away by running the same calendar
//      sync the hourly job runs (public.huddle_calendar_sync). Both of their
//      addresses come off every series quietly and they get one note.
//      History: added 2026-09-03 after John Kostov stayed on the Daily Kickoff
//      invite for days after his termination. Moved onto the shared sync
//      2026-09-25 when the team got three meetings.
//   8. Sends the email to Peter's State Farm address via Composio Gmail.
//   9. Telegram group: the database removes them the moment the step 3 update
//      is saved (trigger team_telegram_offboard -> telegram_group_remove_member:
//      ban + unban so a future invite still works, invite links pulled, one
//      line to the admin group). This function reads back what it recorded.
//  10. Logs everything to automation_run_log; failures land in tasks so Peter
//      can see + retry.
//
// Email, calendar and Telegram are best-effort: the DB state is the source of
// truth for whether the termination happened. External failures create tasks
// but do not roll back the archive.

// deno-lint-ignore-file no-explicit-any

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const COMPOSIO_GMAIL_URL = "https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL";
const NOTICE_RECIPIENT = "peter.story.yrru@statefarm.com";

// Every reply carries the CORS headers. The site calls this from the browser,
// and without them the browser throws the reply away.
function json(body: unknown, status = 200): Response {
  return corsJson(body, status);
}

function htmlEscape(s: string | null | undefined): string {
  if (s === null || s === undefined) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function fmtDate(d: string | null | undefined): string {
  if (!d) return "—";
  try {
    const dt = new Date(d.length === 10 ? d + "T00:00:00" : d);
    return dt.toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
  } catch {
    return d;
  }
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Convert the small markdown subset used in admin_pages → HTML.
// Supports: list bullets (- item), bold (**x**), italics (*x* / _x_),
// inline links [text](url), and paragraph breaks. No nested lists.
function checklistMdToHtml(md: string): string {
  const lines = md.split("\n");
  const out: string[] = [];
  let inList = false;
  for (const raw of lines) {
    const line = raw.trim();
    if (line === "---" || line === "") {
      if (inList) { out.push("</ul>"); inList = false; }
      continue;
    }
    const bullet = line.match(/^[-*]\s+(.*)$/);
    if (bullet) {
      if (!inList) { out.push("<ul style='margin:0 0 8px 18px;padding:0;line-height:1.55;'>"); inList = true; }
      out.push(`<li>${inlineFmt(bullet[1])}</li>`);
      continue;
    }
    if (inList) { out.push("</ul>"); inList = false; }
    out.push(`<p style='margin:6px 0;line-height:1.55;'>${inlineFmt(line)}</p>`);
  }
  if (inList) out.push("</ul>");
  return out.join("\n");
}
function inlineFmt(s: string): string {
  let out = htmlEscape(s);
  out = out.replace(/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g, '<a href="$2" style="color:#0b5394;">$1</a>');
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, "<em>$1</em>");
  out = out.replace(/_([^_]+)_/g, "<em>$1</em>");
  return out;
}

interface TerminateBody {
  team_id: string;
  termination_date: string;
  termination_reason: string;
  reason_category?: string | null;
  final_paycheck_date?: string | null;
}

async function logAlert(severity: string, title: string, message: string): Promise<void> {
  try {
    await ensureWatcherTask({
      agencyId: AGENCY_ID,
      source: `termination_partial_failure:${title}`,
      relatedId: null,
      title,
      description: message,
      priority: severity === "critical" || severity === "high" ? "high" : "medium",
      category: "team_development",
    });
  } catch (e) {
    console.error("logAlert failed:", e);
  }
}

Deno.serve(async (req: Request) => {
  // The browser asks permission before the real call (CORS preflight). Answering
  // it with a 405 is what made the site report "Failed to send a request".
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // Only the owner terminates. The platform check lets any valid key through,
  // including the site's public one, so check who is actually asking.
  const denied = await requireOwner(req, AGENCY_ID);
  if (denied) return denied;

  let body: TerminateBody;
  try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }

  if (!body.team_id || !body.termination_date || !body.termination_reason) {
    return json({ error: "team_id, termination_date, termination_reason are required" }, 400);
  }

  const runStarted = new Date();
  const auditLog: string[] = [];
  const warnings: string[] = [];

  try {
    // 1) Load member
    const { data: member, error: memErr } = await sb.from("team")
      .select("id, user_id, first_name, last_name, nickname, role, role_level, role_category, employment_type, hire_date, start_date, sf_alias, phone_extension, email_personal, email_sf, phone_personal, address_line1, address_line2, city, state, zip_code, archived_at, telegram_user_id")
      .eq("id", body.team_id)
      .eq("agency_id", AGENCY_ID)
      .maybeSingle();
    if (memErr) return json({ error: `team lookup: ${memErr.message}` }, 500);
    if (!member) return json({ error: "team member not found" }, 404);
    if (member.archived_at) return json({ error: `already archived at ${member.archived_at}` }, 409);
    const fullName = `${member.first_name} ${member.last_name}`;
    auditLog.push(`Loaded ${fullName}`);

    // 2) Load the termination checklist (Team → Termination tab).
    const { data: termRow } = await sb.from("termination_checklist")
      .select("content_md")
      .eq("agency_id", AGENCY_ID)
      .maybeSingle();
    let checklistMd = (termRow?.content_md || "").trim()
      ? termRow.content_md
      : "(No termination checklist saved. Add one on the Team → Termination tab.)";
    // Pre-fill the AAO request-details placeholders with the actual values.
    const aliasFill = member.sf_alias || "(no alias on file)";
    const extFill = member.phone_extension || "(no extension on file)";
    checklistMd = checklistMd
      .replace(/Who is being removed/gi, `Who is being removed → **${fullName}**`)
      .replace(/^\s*-\s+Alias\s*$/gim, `- Alias → **${aliasFill}**`)
      .replace(/^\s*-\s+Old extension(.*)$/gim, `- Old extension → **${extFill}**`);
    auditLog.push("Loaded + pre-filled termination checklist");

    // 3) Compose email body
    const addressLines: string[] = [];
    if (member.address_line1) addressLines.push(htmlEscape(member.address_line1));
    if (member.address_line2) addressLines.push(htmlEscape(member.address_line2));
    const cityStateZip = [
      member.city,
      [member.state, member.zip_code].filter(Boolean).join(" "),
    ].filter(Boolean).join(", ");
    if (cityStateZip) addressLines.push(htmlEscape(cityStateZip));
    const addressHtml = addressLines.length > 0
      ? addressLines.join("<br>")
      : "<em style='color:#999;'>[not on file]</em>";

    const dateForSubject = new Date(body.termination_date + "T00:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
    const subject = `[Termination] ${fullName} — ${dateForSubject}`;

    const html = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${htmlEscape(subject)}</title></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#222;max-width:680px;margin:0 auto;padding:24px;background:#fafafa;">

<div style="background:#fff;border-radius:8px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,0.06);">

<h2 style="color:#a00;margin:0 0 4px 0;font-size:22px;">Team Member Termination</h2>
<p style="color:#666;margin:0 0 24px 0;font-size:13px;">Termination notice for <strong>${htmlEscape(fullName)}</strong> — effective ${htmlEscape(fmtDate(body.termination_date))}.</p>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:0;">Identity</h3>
<table cellpadding="6" style="border-collapse:collapse;width:100%;font-size:13px;">
<tr><td style="width:180px;color:#666;">Name</td><td>${htmlEscape(fullName)}${member.nickname ? ` (${htmlEscape(member.nickname)})` : ""}</td></tr>
<tr><td style="color:#666;">Role</td><td>${htmlEscape(member.role || "—")}${member.role_level ? ` — ${htmlEscape(member.role_level)}` : ""}${member.role_category ? ` (${htmlEscape(member.role_category)})` : ""}</td></tr>
<tr><td style="color:#666;">Employment Type</td><td>${htmlEscape(member.employment_type || "—")}</td></tr>
<tr><td style="color:#666;">Hire Date</td><td>${htmlEscape(fmtDate(member.hire_date || member.start_date))}</td></tr>
<tr><td style="color:#666;">Termination Date</td><td><strong>${htmlEscape(fmtDate(body.termination_date))}</strong></td></tr>
${body.final_paycheck_date ? `<tr><td style="color:#666;">Final Paycheck Date</td><td>${htmlEscape(fmtDate(body.final_paycheck_date))}</td></tr>` : ""}
${body.reason_category ? `<tr><td style="color:#666;">Reason Category</td><td>${htmlEscape(body.reason_category)}</td></tr>` : ""}
<tr><td style="color:#666;vertical-align:top;">Reason / Notes</td><td style="white-space:pre-wrap;">${htmlEscape(body.termination_reason)}</td></tr>
</table>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">Personal Contact</h3>
<table cellpadding="6" style="border-collapse:collapse;width:100%;font-size:13px;">
<tr><td style="width:180px;color:#666;vertical-align:top;">Personal Email</td><td>${member.email_personal ? `<a href="mailto:${htmlEscape(member.email_personal)}" style="color:#0b5394;">${htmlEscape(member.email_personal)}</a>` : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
<tr><td style="color:#666;vertical-align:top;">Personal Phone</td><td>${member.phone_personal ? htmlEscape(member.phone_personal) : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
<tr><td style="color:#666;vertical-align:top;">Physical Address</td><td>${addressHtml}</td></tr>
</table>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">State Farm Identifiers</h3>
<table cellpadding="6" style="border-collapse:collapse;width:100%;font-size:13px;">
<tr><td style="width:180px;color:#666;">SF Alias</td><td><strong>${member.sf_alias ? htmlEscape(member.sf_alias) : "<em style='color:#999;'>[not on file]</em>"}</strong></td></tr>
<tr><td style="color:#666;">Phone Extension</td><td>${member.phone_extension ? htmlEscape(member.phone_extension) : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
<tr><td style="color:#666;">SF Email</td><td>${member.email_sf ? htmlEscape(member.email_sf) : "<em style='color:#999;'>[not on file]</em>"}</td></tr>
</table>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">Termination Checklist (from admin_pages)</h3>
<div style="background:#f7f7f7;padding:14px 18px;border-left:4px solid #a00;border-radius:4px;font-size:13px;">
${checklistMdToHtml(checklistMd)}
</div>

<h3 style="border-bottom:2px solid #a00;padding-bottom:4px;font-size:14px;margin-top:24px;">Newtworks Automated Actions</h3>
<ul style="line-height:1.7;font-size:13px;margin:8px 0 0 0;padding-left:20px;">
<li>Archived in Newtworks database (<code>team.archived_at</code>)</li>
<li>Linked user login deactivated (if any)</li>
<li>Stripped from the Team List page in Processes</li>\n<li>Taken off every team meeting invite (work + personal address)</li>
<li>Blocked from both Telegram bots</li>
<li>${member.telegram_user_id ? "Removed from the team Telegram group" : "No Telegram account on file; any group invite link pulled"}</li>
</ul>

<p style="color:#999;margin-top:32px;font-size:11px;border-top:1px solid #ddd;padding-top:14px;">
Sent by the Newtworks on ${new Date().toLocaleString("en-US", { timeZone: "America/Chicago", dateStyle: "full", timeStyle: "short" })} CT.
</p>

</div>
</body></html>`;
    auditLog.push(`Composed email (${html.length} chars)`);

    // 4) Update team row
    const nowIso = new Date().toISOString();
    const { error: teamErr, data: teamUpd } = await sb.from("team").update({
      archived_at: nowIso,
      end_date: body.termination_date,
      is_active: false,
      termination_reason: body.termination_reason,
      final_paycheck_date: body.final_paycheck_date || null,
      // Step 5: blocked from both Telegram bots.
      is_excluded_pjsagencybot: true,
      is_excluded_paper_newt_bot: true,
      updated_at: nowIso,
    }).eq("id", body.team_id).eq("agency_id", AGENCY_ID).select("id");
    if (teamErr) return json({ error: `team update: ${teamErr.message}`, audit_log: auditLog }, 500);
    if (!teamUpd || teamUpd.length === 0) {
      return json({ error: "team update affected 0 rows (RLS?)", audit_log: auditLog }, 500);
    }
    auditLog.push("Updated team row; blocked from both Telegram bots");

    // 5) Deactivate linked user
    if (member.user_id) {
      const { error: usrErr } = await sb.from("users").update({
        is_active: false,
        invite_status: "deactivated",
        updated_at: nowIso,
      }).eq("id", member.user_id).eq("agency_id", AGENCY_ID);
      if (usrErr) warnings.push(`users update: ${usrErr.message}`);
      else auditLog.push("Deactivated linked user");
    }

    // 6) Telegram group. The removal already ran inside the database when the
    //    step 4 update was saved (team_telegram_offboard -> telegram_group_remove_member).
    //    Read back what it recorded for this departure.
    let telegramKicked = false;
    let telegramErrMsg: string | null = null;
    const telegramUserId: number | null = member.telegram_user_id ?? null;
    {
      const { data: rem, error: remErr } = await sb.from("telegram_group_removals")
        .select("telegram_user_id, removed_at, api_result")
        .eq("agency_id", AGENCY_ID).eq("team_id", body.team_id).eq("route_key", "team")
        .order("removed_at", { ascending: false }).limit(1).maybeSingle();
      const fresh = rem && new Date(rem.removed_at).getTime() >= new Date(nowIso).getTime() - 10 * 60_000;
      if (remErr) {
        telegramErrMsg = `telegram removal lookup: ${remErr.message}`;
      } else if (!fresh) {
        telegramErrMsg = "no Telegram group removal was recorded for this termination";
      } else if (!rem.telegram_user_id) {
        auditLog.push("No Telegram account on file; any group invite link was pulled");
      } else if (rem.api_result?.ban?.ok === true) {
        telegramKicked = true;
        auditLog.push(`Removed Telegram user ${rem.telegram_user_id} from the team group`);
      } else {
        telegramErrMsg = `Telegram group removal failed: ${JSON.stringify(rem.api_result ?? {}).slice(0, 300)}`;
      }
    }

    // 7) Strip from "Team List" processes page (best-effort)
    try {
      const { data: pages, error: pbErr } = await sb.from("manuals")
        .select("id, content")
        .eq("agency_id", AGENCY_ID)
        .eq("manual_type", "processes")
        .eq("title", "Team List")
        .limit(1);
      if (pbErr) warnings.push(`Team List lookup: ${pbErr.message}`);
      else if (pages && pages.length > 0) {
        const page = pages[0];
        const original: string = page.content || "";
        const nameRe = new RegExp(
          `(^|\\n\\n)${escapeRegex(member.first_name)}\\s+${escapeRegex(member.last_name)}\\s*\\n(?:[ \\t]*-[^\\n]*\\n?)+`,
          "gi"
        );
        let next = original.replace(nameRe, (_match, lead) => lead || "");
        next = next.replace(/\n{3,}/g, "\n\n").replace(/\s+$/, "") + "\n";
        if (next !== original) {
          const { error: upErr } = await sb.from("manuals").update({
            content: next,
            updated_at: nowIso,
          }).eq("id", page.id);
          if (upErr) warnings.push(`Team List update: ${upErr.message}`);
          else auditLog.push("Stripped from Team List page");
        } else {
          warnings.push(`Could not locate ${fullName}'s block in Team List page`);
        }
      } else {
        warnings.push("Team List processes page not found");
      }
    } catch (e) {
      warnings.push(`processes strip exception: ${e instanceof Error ? e.message : String(e)}`);
    }

    // 7b) Take them off every team meeting invite (best-effort). The team row
    // is archived above, so the calendar sync drops both of their addresses
    // from every series quietly and sends them one note. Same function as the
    // hourly job, so there is no second removal path to drift from it.
    const calendarRemoved: string[] = [];
    const calendarLater: string[] = [];
    try {
      const { data: sync, error: syncErr } = await sb.rpc("huddle_calendar_sync", { p_agency_id: AGENCY_ID });
      if (syncErr) {
        warnings.push(`team meeting invite sync: ${syncErr.message}`);
        await logAlert("warning", `Meeting invite removal failed for ${fullName}`,
          `${fullName} was terminated but the team meeting invites could not be updated (${syncErr.message}). The hourly calendar sync will try again; check that they are off the Daily Kickoff, Coffee and Donuts and Daily Wrap-up.`);
      } else {
        const mine = [member.email_sf, member.email_personal]
          .filter((e): e is string => typeof e === "string" && e.trim() !== "")
          .map((e) => e.trim().toLowerCase());
        for (const m of Object.values((sync?.meetings ?? {}) as Record<string, any>)) {
          const removed: string[] = Array.isArray(m?.removed) ? m.removed : [];
          const hit = removed.filter((e) => mine.includes(e));
          if (hit.length > 0) calendarRemoved.push(`${m?.title}: ${hit.join(", ")}`);
          else if (m?.status === "blocked" || m?.reason === "last change still on its way") {
            calendarLater.push(String(m?.title ?? "a team meeting"));
          }
        }
        if (calendarRemoved.length > 0) auditLog.push(`Taken off team meeting invites: ${calendarRemoved.join("; ")}`);
        if (calendarLater.length > 0) auditLog.push(`Invite removal waits for the next hourly sync: ${calendarLater.join(", ")}`);
        if (calendarRemoved.length === 0 && calendarLater.length === 0) auditLog.push("Was not on any team meeting invite");
      }
    } catch (e) {
      warnings.push(`team meeting invite sync exception: ${e instanceof Error ? e.message : String(e)}`);
    }

    // 8) Send email via Composio Gmail (best-effort)
    let emailSent = false;
    let emailErrMsg: string | null = null;
    try {
      const apiKey = await getSetting(AGENCY_ID, "composio_api_key");
      const userId = await getSetting(AGENCY_ID, "composio_user_id");
      const connId = await getSetting(AGENCY_ID, "composio_gmail_account_id");
      if (!apiKey || !userId || !connId) {
        emailErrMsg = "Composio Gmail config missing in settings";
      } else {
        const res = await fetch(COMPOSIO_GMAIL_URL, {
          method: "POST",
          headers: { "x-api-key": apiKey, "Content-Type": "application/json" },
          body: JSON.stringify({
            user_id: userId,
            connected_account_id: connId,
            arguments: {
              recipient_email: NOTICE_RECIPIENT,
              subject,
              body: html,
              is_html: true,
            },
          }),
        });
        const text = await res.text();
        if (!res.ok) {
          emailErrMsg = `Composio HTTP ${res.status}: ${text.slice(0, 400)}`;
        } else {
          emailSent = true;
          auditLog.push(`Email sent to ${NOTICE_RECIPIENT}`);
        }
      }
    } catch (e) {
      emailErrMsg = `email send exception: ${e instanceof Error ? e.message : String(e)}`;
    }
    if (!emailSent && emailErrMsg) {
      warnings.push(emailErrMsg);
      await logAlert("warning", `Termination email failed for ${fullName}`,
        `${emailErrMsg}\n\nSubject: ${subject}\n\nThe team row + Telegram exclusion were applied. The email did NOT deliver — manual notification needed.`);
    }

    if (telegramErrMsg) {
      warnings.push(telegramErrMsg);
      await logAlert("warning", `Telegram kick failed for ${fullName}`,
        `${telegramErrMsg}\n\nTelegram user ID: ${telegramUserId}\n\nThe team row is archived. Manually remove them from the group via Telegram client if needed.`);
    }

    // 10) Log to automation_run_log
    const durationSec = Math.max(1, Math.round((Date.now() - runStarted.getTime()) / 1000));
    const status = warnings.length === 0 ? "success" : "partial_success";
    await sb.from("automation_run_log").insert({
      agency_id: AGENCY_ID,
      recipe_id: null,
      run_at: runStarted.toISOString(),
      status,
      output_summary: `Terminated ${fullName} effective ${body.termination_date}. ` +
        `Audit: ${auditLog.join("; ")}.` +
        (warnings.length > 0 ? ` Warnings: ${warnings.join("; ")}.` : ""),
      duration_seconds: durationSec,
    });

    return json({
      success: true,
      team_id: body.team_id,
      name: fullName,
      termination_date: body.termination_date,
      email_sent: emailSent,
      telegram_kicked: telegramKicked,
      calendar_removed: calendarRemoved,
      audit_log: auditLog,
      warnings,
    });
  } catch (e) {
    const errMsg = e instanceof Error ? e.message : String(e);
    const durationSec = Math.max(1, Math.round((Date.now() - runStarted.getTime()) / 1000));
    await sb.from("automation_run_log").insert({
      agency_id: AGENCY_ID,
      recipe_id: null,
      run_at: runStarted.toISOString(),
      status: "failed",
      output_summary: `terminate-team-member fatal: ${errMsg}. Partial audit: ${auditLog.join("; ")}`,
      duration_seconds: durationSec,
      error_message: errMsg,
    });
    return json({ error: errMsg, audit_log: auditLog }, 500);
  }
});
