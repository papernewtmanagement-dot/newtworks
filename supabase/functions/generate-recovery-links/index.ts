import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Hardcoded allowlist — current active agency team + admin tier.
// Jason Fuller terminated 2026-06-20, removed from allowlist.
// Leslie Jones intentionally never invited.
const ALLOWED_EMAILS: Record<string, true> = {
  "angracassie13@gmail.com": true,
  "john.kostov@gmail.com": true,
  "slrogers729@gmail.com": true,
  "tlynch1874@gmail.com": true,
  "alvipelo@gmail.com": true, // Marie Story (manager)
};

const APP_URL = "https://storybccdashboard.vercel.app/";

/**
 * v4 (2026-06-30): Add `send_email` mode that triggers Supabase's native
 *   recovery email via supabase.auth.resetPasswordForEmail() on the anon
 *   client. This bypasses the Composio Gmail send pipeline, which corrupts
 *   any URL containing `=<hex><hex>` (e.g. Supabase magic-link tokens) due
 *   to a quoted-printable encoding bug.
 *
 *   send_email defaults to TRUE — never go through Composio for recovery
 *   links again. Set send_email=false explicitly only when you need the raw
 *   link (e.g. for testing or manual delivery via Gmail web UI).
 *
 * v3 (prior): generateLink-only — returned action_link to caller for manual
 *   email composition.
 */

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const requested = Array.isArray((body as { emails?: unknown }).emails)
    ? ((body as { emails: unknown[] }).emails as unknown[])
    : [];
  const targets = requested
    .filter((e): e is string => typeof e === "string")
    .map((e) => e.toLowerCase())
    .filter((e) => ALLOWED_EMAILS[e]);

  // Default to sending the actual email via Supabase native. Caller can opt
  // out by passing send_email=false to get just the link.
  const sendEmail = (body as { send_email?: unknown }).send_email !== false;

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const supabase = createClient(
    SUPABASE_URL,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  // Anon client used for resetPasswordForEmail. The admin client does NOT
  // expose a "send recovery email" method — only generateLink (which doesn't
  // send). resetPasswordForEmail on the anon client triggers Supabase's
  // configured email template via Supabase's own SMTP.
  const supabaseAnon = createClient(
    SUPABASE_URL,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  // Page through auth.users once — used to look up auth user ID by email
  // so we can auto-confirm unconfirmed accounts before issuing recovery links.
  // Recovery links fail with "invalid credentials" on email_confirmed_at = null
  // (e.g. user invited but never clicked original invite within TTL).
  const authUsersByEmail = new Map<string, { id: string; email_confirmed_at: string | null }>();
  {
    let page = 1;
    const perPage = 1000;
    while (true) {
      const { data, error } = await supabase.auth.admin.listUsers({ page, perPage });
      if (error || !data?.users?.length) break;
      for (const u of data.users) {
        if (u.email) {
          authUsersByEmail.set(u.email.toLowerCase(), {
            id: u.id,
            email_confirmed_at: u.email_confirmed_at ?? null,
          });
        }
      }
      if (data.users.length < perPage) break;
      page += 1;
    }
  }

  const results: Array<Record<string, unknown>> = [];
  for (const email of targets) {
    // Primary lookup: team table (staff have separate auth email = email_sf).
    let authEmail: string | null = null;
    const { data: teamRow } = await supabase
      .from("team")
      .select("id, email_personal, email_sf")
      .eq("email_personal", email)
      .maybeSingle();

    if (teamRow) {
      authEmail = teamRow.email_sf || teamRow.email_personal;
    } else {
      // Fallback: admin tier (owner/manager) — not in team table.
      // Use public.users.email as the auth email directly.
      const { data: userRow, error: userErr } = await supabase
        .from("users")
        .select("id, email, role")
        .eq("email", email)
        .maybeSingle();

      if (userErr || !userRow) {
        results.push({
          personal_email: email,
          ok: false,
          error: userErr?.message ?? "no team or users row matched",
        });
        continue;
      }
      authEmail = userRow.email;
    }

    // Auto-confirm email if user exists but is in unconfirmed purgatory.
    // Idempotent: skip if already confirmed.
    const authUser = authUsersByEmail.get(authEmail.toLowerCase());
    let auto_confirmed = false;
    if (authUser && !authUser.email_confirmed_at) {
      const { error: confirmErr } = await supabase.auth.admin.updateUserById(
        authUser.id,
        { email_confirm: true },
      );
      if (confirmErr) {
        results.push({
          personal_email: email,
          auth_email: authEmail,
          ok: false,
          error: `auto-confirm failed: ${confirmErr.message}`,
        });
        continue;
      }
      auto_confirmed = true;
    }

    if (sendEmail) {
      // Native Supabase recovery email path. Sends via Supabase's configured
      // SMTP using the project's "Reset Password" email template. Token is
      // embedded server-side, never passes through any external email layer,
      // so URL encoding hazards are eliminated.
      const { error: sendErr } = await supabaseAnon.auth.resetPasswordForEmail(
        authEmail,
        { redirectTo: APP_URL },
      );
      results.push({
        personal_email: email,
        auth_email: authEmail,
        auto_confirmed,
        mode: "send_email",
        ok: !sendErr,
        sent: !sendErr,
        error: sendErr?.message ?? null,
      });
    } else {
      // Legacy: just return the link for manual delivery. Use this only when
      // you need to paste into Gmail's web composer directly (the Composio
      // pipeline corrupts these URLs — do not feed action_link back into any
      // Composio Gmail tool).
      const { data: linkData, error: linkErr } = await supabase.auth.admin.generateLink({
        type: "recovery",
        email: authEmail,
        options: { redirectTo: APP_URL },
      });
      results.push({
        personal_email: email,
        auth_email: authEmail,
        auto_confirmed,
        mode: "link_only",
        ok: !linkErr,
        action_link: linkData?.properties?.action_link ?? null,
        hashed_token: linkData?.properties?.hashed_token ?? null,
        error: linkErr?.message ?? null,
      });
    }
  }

  return new Response(
    JSON.stringify({
      requested: requested.length,
      allowlisted: targets.length,
      mode: sendEmail ? "send_email" : "link_only",
      results,
    }),
    { headers: { "Content-Type": "application/json" } },
  );
});
