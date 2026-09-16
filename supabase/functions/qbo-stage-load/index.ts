import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

type Row = {
  agency_id: string;
  fiscal_year: number;
  account_name: string;
  entry_date: string; // YYYY-MM-DD
  amount: number | string;
  description?: string;
  memo?: string;
  source_tag?: string;
};

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST required" }), { status: 405 });
  }
  
  // Shared-secret auth using the cron_secret from settings table
  const authHeader = req.headers.get("x-bcc-secret") || "";
  const expectedSecret = Deno.env.get("BCC_CRON_SECRET") || "";
  if (!expectedSecret || authHeader !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }
  
  let body: { rows: Row[] };
  try {
    body = await req.json();
  } catch (e) {
    return new Response(JSON.stringify({ error: "invalid_json", detail: String(e) }), { status: 400 });
  }
  const rows = body?.rows;
  if (!Array.isArray(rows) || rows.length === 0) {
    return new Response(JSON.stringify({ error: "rows array required" }), { status: 400 });
  }
  if (rows.length > 5000) {
    return new Response(JSON.stringify({ error: "max 5000 rows per call" }), { status: 400 });
  }
  
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const client = createClient(supabaseUrl, serviceKey);
  
  // Insert into staging in chunks of 1000
  const CHUNK = 1000;
  let inserted = 0;
  for (let i = 0; i < rows.length; i += CHUNK) {
    const chunk = rows.slice(i, i + CHUNK).map(r => ({
      agency_id: r.agency_id,
      fiscal_year: r.fiscal_year,
      account_name: r.account_name,
      entry_date: r.entry_date,
      amount: typeof r.amount === "string" ? parseFloat(r.amount) : r.amount,
      description: r.description ?? null,
      memo: r.memo ?? null,
      source_tag: r.source_tag ?? "qbo_import",
    }));
    const { error } = await client.from("qbo_import_staging").insert(chunk);
    if (error) {
      return new Response(JSON.stringify({ error: "insert_failed", detail: error.message, inserted_so_far: inserted }), { status: 500 });
    }
    inserted += chunk.length;
  }
  
  return new Response(JSON.stringify({ ok: true, inserted }), {
    headers: { "Content-Type": "application/json" }
  });
});
