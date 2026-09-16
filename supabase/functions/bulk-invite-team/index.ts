import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Hardcoded allowlist — this endpoint can only invite these 5 specific emails.
// Leslie Jones (jnrheart@gmail.com) deliberately omitted at Peter's instruction.
// Even with verify_jwt=false, the worst an attacker can do is re-trigger an
// invite email to one of these already-approved addresses.
const ALLOWED_EMAILS: Record<string, true> = {
  "angracassie13@gmail.com": true,
  "thejdfuller@gmail.com": true,
  "john.kostov@gmail.com": true,
  "slrogers729@gmail.com": true,
  "tlynch1874@gmail.com": true,
};

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
  const emails = requested
    .filter((e): e is string => typeof e === "string")
    .map((e) => e.toLowerCase())
    .filter((e) => ALLOWED_EMAILS[e]);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  const results: Array<Record<string, unknown>> = [];
  for (const email of emails) {
    const { data, error } = await supabase.auth.admin.inviteUserByEmail(email);
    results.push({
      email,
      ok: !error,
      auth_user_id: data?.user?.id ?? null,
      error: error?.message ?? null,
    });
  }

  return new Response(
    JSON.stringify({
      requested: requested.length,
      allowlisted: emails.length,
      results,
    }),
    { headers: { "Content-Type": "application/json" } },
  );
});
