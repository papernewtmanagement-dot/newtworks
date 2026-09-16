// payroll-email-parser — DEPRECATED 2026-07-07.
//
// This edge function was consolidated into `document-processor` v37 as part of
// the single Gmail-intake pipeline. The SurePayroll deterministic parser now
// lives inside document-processor under docType `surepayroll_payroll`.
//
// This stub is a tombstone: it exists only because Supabase MCP has no
// delete-edge-function tool. Any invocation returns 410 Gone with a pointer
// to the successor. Nothing in the codebase should be hitting this URL. If
// you see a 410 in logs, find the caller and update it to invoke
// `document-processor` with an optional `gmail_query` body param instead.
//
// Fully removing this fn requires running:
//   supabase functions delete payroll-email-parser --project-ref vulhdujhbwvibbojiimi

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

Deno.serve((_req: Request) => {
  const body = {
    ok: false,
    error: "gone",
    message: "payroll-email-parser was deprecated on 2026-07-07. SurePayroll parsing now lives inside document-processor as docType `surepayroll_payroll`. Invoke document-processor with an optional `gmail_query` body param for scoped runs.",
    successor: "document-processor",
    deprecated_at: "2026-07-07",
  };
  return new Response(JSON.stringify(body, null, 2), {
    status: 410,
    headers: { "Content-Type": "application/json" },
  });
});
