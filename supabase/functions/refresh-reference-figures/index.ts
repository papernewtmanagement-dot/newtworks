import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";

const ALLOWED_DOMAINS = ["irs.gov", "ssa.gov", "cms.gov", "medicare.gov", "hhs.gov", "fhfa.gov"];

const AUTHORITY_DOMAINS = {
  IRS: ["irs.gov"],
  SSA: ["ssa.gov"],
  CMS: ["cms.gov", "medicare.gov"],
  HHS: ["hhs.gov", "cms.gov"],
  FHFA: ["fhfa.gov"],
};

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function askGroq(groqKey, authority, targetYear, figures) {
  const domains = AUTHORITY_DOMAINS[authority] ?? ALLOWED_DOMAINS;

  const wanted = figures
    .map((f) => `- ${f.figure_key} | ${f.label} | unit: ${f.unit} | on file for ${f.tax_year}: ${f.value_display}`)
    .join("\n");

  const prompt =
    `You are retrieving official United States federal figures for tax year ${targetYear}.\n\n` +
    `Search only ${domains.join(", ")} and report what those sources state for ${targetYear}.\n\n` +
    `Figures needed:\n${wanted}\n\n` +
    `Rules:\n` +
    `1. Report the ${targetYear} value. If a source only shows an earlier year, that is NOT the ${targetYear} value.\n` +
    `2. If you cannot confirm a figure for ${targetYear} from those sources, set value_display to null and confident to false. Never estimate, never carry forward the prior year, never infer from a percentage increase.\n` +
    `3. Format value_display exactly like the value on file: digits with thousands separators, no currency symbol, no words (example: 4,400 or 202.90). For unit percent give just the number (example: 2.8). For unit text match the existing style (example: 15 million).\n` +
    `4. source_url must be the specific page you took the number from.\n\n` +
    `Respond with ONLY a JSON object, no prose and no markdown fences:\n` +
    `{"findings":[{"figure_key":"...","value_display":"...","tax_year":${targetYear},"source_url":"...","confident":true,"note":""}]}`;

  const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${groqKey}`,
      "Groq-Model-Version": "latest",
    },
    body: JSON.stringify({
      model: "groq/compound-mini",
      messages: [{ role: "user", content: prompt }],
      temperature: 0,
      compound_custom: {
        tools: { enabled_tools: ["web_search"] },
        search_settings: { include_domains: domains },
      },
    }),
  });

  if (res.status === 429) {
    const body = await res.text();
    const hint = /try again in ([0-9.]+)s/.exec(body);
    const waitMs = Math.min(30000, Math.ceil((hint ? parseFloat(hint[1]) : 8) * 1000) + 1500);
    throw new RateLimited(waitMs, `Groq TPM limit for ${authority}, retry in ${waitMs}ms`);
  }
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Groq ${res.status} for ${authority}: ${body.slice(0, 400)}`);
  }

  const data = await res.json();
  const msg = data?.choices?.[0]?.message ?? {};
  const raw = msg.content ?? "";
  const cleaned = raw.replace(/```json/gi, "").replace(/```/g, "").trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start === -1 || end === -1) {
    throw new Error(`Groq returned no JSON for ${authority}: ${raw.slice(0, 300)}`);
  }
  const parsed = JSON.parse(cleaned.slice(start, end + 1));
  return { findings: parsed.findings ?? [] };
}

class RateLimited extends Error {
  waitMs;
  constructor(waitMs, msg) { super(msg); this.waitMs = waitMs; }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function askGroqWithRetry(groqKey, authority, targetYear, figures, attempts = 4) {
  for (let i = 1; i <= attempts; i++) {
    try {
      return await askGroq(groqKey, authority, targetYear, figures);
    } catch (e) {
      if (e instanceof RateLimited && i < attempts) {
        await sleep(e.waitMs + Math.floor(Math.random() * 800));
        continue;
      }
      throw e;
    }
  }
  throw new Error("unreachable");
}

// ONE small batch per invocation. Compound's web search is token-heavy and
// slow, so a whole authority in one run exceeds both the per-minute ceiling and
// the function's wall clock. The cron re-runs through the refresh window and
// works the queue down; every run is idempotent because the queue is simply
// "figures whose tax_year is still behind the target".
const BATCH = 1;

Deno.serve(async (req) => {
  const started = Date.now();
  try {
    const body = await req.json().catch(() => ({}));
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));

    const { data: settings } = await supabase
      .from("settings").select("setting_value")
      .eq("agency_id", AGENCY_ID).eq("setting_key", "groq_api_key").maybeSingle();

    const groqKey = settings?.setting_value;
    if (!groqKey) return jsonResponse({ ok: false, error: "settings.groq_api_key not set" }, 400);

    const now = new Date();
    const targetYear = body.target_year ?? (now.getMonth() >= 10 ? now.getFullYear() + 1 : now.getFullYear());
    const dryRun = body.dry_run === true;

    const { data: stale, error: figErr } = await supabase
      .from("reference_figures")
      .select("id, figure_key, label, value_display, unit, tax_year, source_authority")
      .eq("agency_id", AGENCY_ID).eq("is_active", true).lt("tax_year", targetYear)
      .neq("figure_key", "figures_tax_year")
      .order("source_authority").order("figure_key");

    if (figErr) throw new Error(`figure fetch failed: ${figErr.message}`);

    const queueDepth = stale?.length ?? 0;

    if (queueDepth === 0) {
      // Everything real is current; advance the display year last.
      const { data: meta } = await supabase.from("reference_figures")
        .select("id, value_display, tax_year")
        .eq("agency_id", AGENCY_ID).eq("figure_key", "figures_tax_year").maybeSingle();

      if (meta && meta.tax_year < targetYear && !dryRun) {
        await supabase.from("reference_figures").update({
          previous_value_display: meta.value_display,
          previous_tax_year: meta.tax_year,
          value_display: String(targetYear),
          tax_year: targetYear,
          last_verified_at: new Date().toISOString(),
          verified_by: "groq",
          updated_at: new Date().toISOString(),
        }).eq("id", meta.id);

        return jsonResponse({
          ok: true, records_processed: 1, queue_depth: 0,
          output_summary: `All figures confirmed for ${targetYear}; advanced figures_tax_year to ${targetYear}.`,
        });
      }
      return jsonResponse({
        ok: true, records_processed: 0, queue_depth: 0,
        output_summary: `Nothing stale. All figures already at tax year ${targetYear}.`,
      });
    }

    // Batch = up to BATCH figures from a single authority (search domains differ per authority).
    const authority = stale[0].source_authority;
    const group = stale.filter((f) => f.source_authority === authority).slice(0, BATCH);
    const allowed = AUTHORITY_DOMAINS[authority] ?? ALLOWED_DOMAINS;

    const updated = [];
    const unconfirmed = [];
    const failures = [];

    let findings = [];
    try {
      const result = await askGroqWithRetry(groqKey, authority, targetYear, group);
      findings = result.findings;
    } catch (e) {
      failures.push(`${authority}: ${e.message}`);
    }

    for (const row of group) {
      const found = findings.find((f) => f.figure_key === row.figure_key);

      if (!found || !found.confident || !found.value_display) {
        unconfirmed.push(`${row.figure_key} (${found?.note ?? "not returned"})`);
        continue;
      }
      if (found.tax_year !== targetYear) {
        unconfirmed.push(`${row.figure_key} (returned year ${found.tax_year})`);
        continue;
      }
      const url = found.source_url ?? "";
      if (!allowed.some((d) => url.includes(d))) {
        unconfirmed.push(`${row.figure_key} (source not on ${allowed.join("/")}: ${url})`);
        continue;
      }
      const shapeOk = row.unit === "text"
        ? found.value_display.trim().length > 0
        : /^[0-9][0-9,]*(\.[0-9]{1,2})?$/.test(found.value_display.trim());
      if (!shapeOk) {
        unconfirmed.push(`${row.figure_key} (bad format: ${found.value_display})`);
        continue;
      }

      const patch = {
        tax_year: targetYear,
        source_url: url,
        last_verified_at: new Date().toISOString(),
        verified_by: "groq",
        updated_at: new Date().toISOString(),
      };

      if (found.value_display.trim() === row.value_display.trim()) {
        if (!dryRun) await supabase.from("reference_figures").update(patch).eq("id", row.id);
        updated.push(`${row.figure_key} unchanged at ${row.value_display}`);
        continue;
      }

      if (!dryRun) {
        await supabase.from("reference_figures").update({
          ...patch,
          previous_value_display: row.value_display,
          previous_tax_year: row.tax_year,
          value_display: found.value_display.trim(),
        }).eq("id", row.id);
      }
      updated.push(`${row.figure_key} ${row.value_display} -> ${found.value_display.trim()}`);
    }

    // Only shout when a run makes zero progress -- otherwise an hourly cron
    // would spam an alert for every figure not yet published.
    if (updated.length === 0 && !dryRun) {
      const { data: existing } = await supabase.from("alerts").select("id")
        .eq("agency_id", AGENCY_ID).eq("module_reference", "knowledge_faqs")
        .eq("is_resolved", false).ilike("title", `%reference figures%${targetYear}%`).limit(1);

      if (!existing || existing.length === 0) {
        await supabase.from("alerts").insert({
          agency_id: AGENCY_ID,
          module_reference: "knowledge_faqs",
          severity: "warning",
          title: `Reference figures: no progress on ${authority} for ${targetYear}`,
          message:
            `${queueDepth} figures still behind tax year ${targetYear}. This run confirmed none.\n\n` +
            `Could not confirm:\n${unconfirmed.join("\n") || "none"}\n\nErrors:\n${failures.join("\n") || "none"}\n\n` +
            `FAQ answers still show the prior year's figures, and figures_tax_year has NOT advanced, ` +
            `so no answer claims to be ${targetYear}. Likely causes: the agency has not published ${targetYear} ` +
            `values yet (normal before late autumn), or the Groq daily token allowance is exhausted.`,
          is_resolved: false,
        });
      }
    }

    return jsonResponse({
      ok: true,
      records_processed: updated.length,
      queue_depth: queueDepth - updated.length,
      output_summary:
        `${authority} batch, target ${targetYear}${dryRun ? " (dry run)" : ""}: ` +
        `${updated.length} confirmed, ${unconfirmed.length} unconfirmed, ${failures.length} errors, ` +
        `${queueDepth - updated.length} still queued, ${Date.now() - started}ms`,
      updated, unconfirmed, failures,
    });
  } catch (e) {
    return jsonResponse({ ok: false, error: e.message }, 500);
  }
});
