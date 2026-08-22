// =========================================================================
// migration-mirror bundle (auto-generated)
// Source of truth: supabase/functions/migration-mirror/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py migration-mirror`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

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

// ==================== _shared/alerts.ts ====================
// =========================================================================
// _shared/alerts.ts
// =========================================================================
// Canonical alerts writer for ALL Newtworks edge functions.
//
// Why this exists: the alerts table takes (alert_type NOT NULL, severity,
// title, message, module_reference, related_id, is_resolved). Hand-written
// inserts have shipped with a `body:` column that does not exist and with
// alert_type missing — both fail silently when the insert result isn't
// checked. Going through this helper makes that class of bug impossible.
// =========================================================================


async function insertAlert(opts: {
  agencyId: string;
  alertType: string;
  severity: "info" | "warning" | "high" | "critical" | string;
  title: string;
  message: string;
  moduleReference?: string;
  relatedId?: string | null;
}): Promise<{ ok: boolean; error: string | null }> {
  const row: Record<string, unknown> = {
    agency_id: opts.agencyId,
    alert_type: opts.alertType,
    severity: opts.severity,
    title: opts.title,
    message: opts.message,
    is_read: false,
    is_resolved: false,
  };
  if (opts.moduleReference != null) row.module_reference = opts.moduleReference;
  if (opts.relatedId != null) row.related_id = opts.relatedId;

  const { error } = await sb.from("alerts").insert(row);
  if (error) {
    // Never throw — alerting must not mask the underlying failure being
    // reported. But do surface the miss to whoever reads the function logs.
    console.error(`insertAlert failed (${opts.alertType}): ${error.message}`);
    return { ok: false, error: error.message };
  }
  return { ok: true, error: null };
}

// Resolve all open alerts carrying a given module_reference (the standard
// "this condition cleared" pattern used by surepayroll + pfa flows).
async function resolveAlerts(opts: {
  agencyId: string;
  moduleReference: string;
}): Promise<{ ok: boolean; resolved: number; error: string | null }> {
  const { data, error } = await sb
    .from("alerts")
    .update({ is_resolved: true, resolved_at: new Date().toISOString() })
    .eq("agency_id", opts.agencyId)
    .eq("module_reference", opts.moduleReference)
    .eq("is_resolved", false)
    .select("id");
  if (error) {
    console.error(`resolveAlerts failed (${opts.moduleReference}): ${error.message}`);
    return { ok: false, resolved: 0, error: error.message };
  }
  return { ok: true, resolved: (data ?? []).length, error: null };
}

// ==================== migration-mirror/index.ts ====================
// =========================================================================
// migration-mirror
// =========================================================================
// Mirrors the Supabase migration ledger (supabase_migrations.schema_migrations)
// into the repo at supabase/migrations/<version>_<name>.sql.
//
// WHY THIS EXISTS
// Migrations applied through the Supabase MCP land in the ledger but only get a
// repo file if the authoring session remembers to write one. Sessions forget.
// By 2026-08-20 hundreds of applied migrations had no repo file, which means a
// fresh clone + `supabase db reset` could no longer rebuild production. Nothing
// was lost — the ledger stores the full applied SQL for every row — but a hand
// pass cannot fix it, because the missing SQL runs to megabytes and any manual
// route pushes every byte through a chat window.
//
// This function does the whole diff server-side: it reads the repo tree over
// the GitHub API, asks the database which ledger rows have no matching file,
// and commits the missing ones in batches. Run once to backfill, then nightly
// so the gap can never reopen.
//
// TARGET BRANCH
// Defaults to `db`. Migrations and docs route there so mirror commits do not
// each raise a Vercel deployment (vercel.json sets git.deploymentEnabled.db
// = false). `db` gets merged into main on the normal cadence.
//
// ONE COMMIT PER BATCH
// Uses the git data API (blobs -> tree -> commit -> ref) rather than the
// contents API, so a batch of 40 files is ONE commit and ONE ref update, not
// 40 of each. The ref update is non-force: if anything else moved the branch
// between the read and the write, GitHub rejects it and the batch is retried
// against the new head on the next pass rather than clobbering.
//
// REQUEST
//   POST { agency_id, shared_secret,
//          mode?: "check" | "backfill",   // default "backfill"
//          branch?: string,               // default "db"
//          limit?: number,                // files per batch, default 40
//          max_bytes?: number,            // SQL bytes per batch, default 700000
//          max_batches?: number,          // batches per invocation, default 1
//          dry_run?: boolean }
//
// "check" reports the gap and writes nothing.
// =========================================================================


const GH_REPO = "papernewtmanagement-dot/newtworks";
const GH_API = "https://api.github.com";
const MIG_DIR = "supabase/migrations";

// -------------------------------------------------------------------------
// GitHub helpers
// -------------------------------------------------------------------------

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// GitHub enforces a SECONDARY rate limit on content-creating calls that is
// separate from the hourly quota and is not advertised in the normal
// x-ratelimit headers. It answers 403 with a "secondary rate limit" message.
// Backfilling a thousand migrations trips it, so every call retries with
// backoff, honouring Retry-After when GitHub sends one.
async function gh(
  token: string,
  path: string,
  init?: { method?: string; body?: unknown },
  attempt = 0,
): Promise<any> {
  const res = await fetch(`${GH_API}${path}`, {
    method: init?.method ?? "GET",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "newtworks-migration-mirror",
      "Content-Type": "application/json",
    },
    body: init?.body ? JSON.stringify(init.body) : undefined,
  });
  const text = await res.text();

  if (!res.ok) {
    const throttled =
      res.status === 429 ||
      (res.status === 403 && /secondary rate limit|abuse detection/i.test(text));
    if (throttled && attempt < 4) {
      const retryAfter = Number(res.headers.get("retry-after") ?? 0);
      const waitMs = retryAfter > 0 ? retryAfter * 1000 : 2000 * Math.pow(2, attempt);
      await sleep(waitMs);
      return gh(token, path, init, attempt + 1);
    }
    throw new Error(`GitHub ${init?.method ?? "GET"} ${path} -> ${res.status}: ${text.slice(0, 400)}`);
  }
  return text ? JSON.parse(text) : null;
}

// Filenames follow the Supabase CLI convention: <14-digit version>_<name>.sql
function safeName(name: string | null | undefined): string {
  const cleaned = (name ?? "").trim().replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+|_+$/g, "");
  return cleaned.length ? cleaned.slice(0, 160) : "unnamed";
}

// Walk root -> supabase -> migrations and list that ONE directory tree. Cheaper
// and safer than a recursive tree of the whole repo, which can come back
// truncated as the repo grows.
async function listMigrationVersions(
  token: string,
  treeSha: string,
): Promise<{ versions: string[]; fileCount: number }> {
  const root = await gh(token, `/repos/${GH_REPO}/git/trees/${treeSha}`);
  const supa = (root.tree ?? []).find((e: any) => e.path === "supabase" && e.type === "tree");
  if (!supa) return { versions: [], fileCount: 0 };

  const supaTree = await gh(token, `/repos/${GH_REPO}/git/trees/${supa.sha}`);
  const migs = (supaTree.tree ?? []).find((e: any) => e.path === "migrations" && e.type === "tree");
  if (!migs) return { versions: [], fileCount: 0 };

  const migTree = await gh(token, `/repos/${GH_REPO}/git/trees/${migs.sha}`);
  if (migTree.truncated) {
    throw new Error("migrations tree came back truncated — cannot trust the diff, aborting");
  }

  const files = (migTree.tree ?? []).filter((e: any) => e.type === "blob");
  const versions: string[] = [];
  for (const f of files) {
    const m = /^(\d{14})/.exec(f.path);
    if (m) versions.push(m[1]);
  }
  return { versions: Array.from(new Set(versions)), fileCount: files.length };
}

// Same normalisation the database side uses in v_migration_ledger_fingerprints:
// strip -- line comments, strip ALL whitespace, sha256. A mirror that carries an
// added provenance comment header, or that was reflowed, still fingerprints
// equal to its ledger original — which plain blob-hash comparison misses.
async function fingerprint(sql: string): Promise<string> {
  const norm = sql.replace(/--[^\n]*/g, "").replace(/\s+/g, "");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(norm));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

// Full listing (path + blob sha), not just versions — audit needs the paths.
async function listMigrationFiles(
  token: string,
  treeSha: string,
): Promise<Array<{ path: string; sha: string }>> {
  const root = await gh(token, `/repos/${GH_REPO}/git/trees/${treeSha}`);
  const supa = (root.tree ?? []).find((e: any) => e.path === "supabase" && e.type === "tree");
  if (!supa) return [];
  const supaTree = await gh(token, `/repos/${GH_REPO}/git/trees/${supa.sha}`);
  const migs = (supaTree.tree ?? []).find((e: any) => e.path === "migrations" && e.type === "tree");
  if (!migs) return [];
  const migTree = await gh(token, `/repos/${GH_REPO}/git/trees/${migs.sha}`);
  if (migTree.truncated) {
    throw new Error("migrations tree came back truncated — cannot trust the diff, aborting");
  }
  return (migTree.tree ?? [])
    .filter((e: any) => e.type === "blob")
    .map((e: any) => ({ path: e.path, sha: e.sha }));
}

// -------------------------------------------------------------------------
// Handler
// -------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  let body: any = {};
  try {
    body = await req.json();
  } catch (_e) {
    return jsonResponse({ ok: false, error: "invalid JSON body" }, 400);
  }

  const agencyId: string = body.agency_id ?? AGENCY_ID_DEFAULT;
  const denied = await requireSharedSecret(agencyId, body.shared_secret);
  if (denied) return denied;

  const mode: string = body.mode ?? "backfill";
  const branch: string = body.branch ?? "db";
  const limit: number = Math.min(Math.max(Number(body.limit ?? 40), 1), 100);
  const maxBytes: number = Math.min(Math.max(Number(body.max_bytes ?? 700000), 10000), 2000000);
  const maxBatches: number = Math.min(Math.max(Number(body.max_batches ?? 1), 1), 25);
  const dryRun: boolean = body.dry_run === true;

  const started = Date.now();
  const commits: Array<{ sha: string; files: number; bytes: number }> = [];
  let written = 0;
  let stats: any = null;

  try {
    const token = await getSetting(agencyId, "github_pat_newtworks_commit");
    if (!token) throw new Error("settings.github_pat_newtworks_commit is not set");

    // --- audit: fingerprint every repo migration with no ledger row ---------
    if (mode === "audit") {
      const ref = await gh(token, `/repos/${GH_REPO}/git/ref/heads/${branch}`);
      const headCommit = await gh(token, `/repos/${GH_REPO}/git/commits/${ref.object.sha}`);
      const files = await listMigrationFiles(token, headCommit.tree.sha);

      const byVersion = new Map<string, Array<{ path: string; sha: string }>>();
      let noVersion = 0;
      for (const f of files) {
        const m = /^(\d{14})/.exec(f.path);
        if (!m) { noVersion++; continue; }
        const arr = byVersion.get(m[1]) ?? [];
        arr.push(f);
        byVersion.set(m[1], arr);
      }

      const { data: repoOnly, error: roErr } = await sb.rpc("migration_mirror_repo_only", {
        p_repo_versions: Array.from(byVersion.keys()),
      });
      if (roErr) throw new Error(`migration_mirror_repo_only failed: ${roErr.message}`);

      // Every file under a repo-only version, flattened, then paged so a run
      // cannot outlive the function's wall clock.
      const targets: Array<{ version: string; path: string; sha: string }> = [];
      for (const row of repoOnly ?? []) {
        for (const f of byVersion.get((row as any).version) ?? []) {
          targets.push({ version: (row as any).version, path: f.path, sha: f.sha });
        }
      }
      targets.sort((a, b) => (a.path < b.path ? -1 : 1));

      const offset = Math.max(Number(body.offset ?? 0), 0);
      const take = Math.min(Math.max(Number(body.audit_limit ?? 250), 1), 600);
      const slice = targets.slice(offset, offset + take);

      const rows: Array<{ version: string; path: string; fingerprint: string }> = [];
      for (const t of slice) {
        const blob = await gh(token, `/repos/${GH_REPO}/git/blobs/${t.sha}`);
        const raw = blob.encoding === "base64"
          ? new TextDecoder().decode(
              Uint8Array.from(atob(blob.content.replace(/\n/g, "")), (c) => c.charCodeAt(0)),
            )
          : String(blob.content ?? "");
        rows.push({ version: t.version, path: t.path, fingerprint: await fingerprint(raw) });
      }

      let tally: any = null;
      if (rows.length) {
        const { data: rec, error: recErr } = await sb.rpc("migration_mirror_record_audit", {
          p_agency_id: agencyId,
          p_rows: rows,
        });
        if (recErr) throw new Error(`migration_mirror_record_audit failed: ${recErr.message}`);
        tally = rec?.[0] ?? null;
      }

      return jsonResponse({
        ok: true,
        mode: "audit",
        branch,
        head: ref.object.sha,
        repo_files: files.length,
        files_without_version: noVersion,
        repo_versions: byVersion.size,
        repo_only_versions: (repoOnly ?? []).length,
        audit_targets: targets.length,
        offset,
        checked_this_run: rows.length,
        next_offset: offset + rows.length < targets.length ? offset + rows.length : null,
        running_tally: tally,
        elapsed_ms: Date.now() - started,
      });
    }

    for (let batch = 0; batch < maxBatches; batch++) {
      // --- read the branch head fresh every batch -------------------------
      const ref = await gh(token, `/repos/${GH_REPO}/git/ref/heads/${branch}`);
      const headSha: string = ref.object.sha;
      const headCommit = await gh(token, `/repos/${GH_REPO}/git/commits/${headSha}`);
      const baseTree: string = headCommit.tree.sha;

      const { versions, fileCount } = await listMigrationVersions(token, baseTree);

      // --- what does the ledger have that the repo does not? --------------
      const { data: statRows, error: statErr } = await sb.rpc("migration_mirror_stats", {
        p_have: versions,
      });
      if (statErr) throw new Error(`migration_mirror_stats failed: ${statErr.message}`);
      stats = {
        ledger_total: statRows?.[0]?.ledger_total ?? null,
        repo_versions: versions.length,
        repo_files: fileCount,
        pending: statRows?.[0]?.pending ?? null,
        pending_bytes: statRows?.[0]?.pending_bytes ?? null,
        branch,
        head: headSha,
      };

      if (mode === "check") break;
      if (!stats.pending) break;

      const { data: pending, error: pendErr } = await sb.rpc("migration_mirror_pending", {
        p_have: versions,
        p_limit: limit,
        p_max_bytes: maxBytes,
      });
      if (pendErr) throw new Error(`migration_mirror_pending failed: ${pendErr.message}`);
      if (!pending || pending.length === 0) break;

      if (dryRun) {
        commits.push({
          sha: "(dry-run)",
          files: pending.length,
          bytes: pending.reduce((a: number, r: any) => a + r.bytes, 0),
        });
        break;
      }

      // --- one tree, one commit, one ref update ---------------------------
      // File content goes INLINE in the tree call. The obvious alternative —
      // POST a blob per file, then reference each blob sha — costs one extra
      // request per file and trips GitHub's secondary rate limit partway
      // through a backfill of this size. Inline content is UTF-8 only, which
      // is exactly what SQL is.
      const treeEntries: Array<Record<string, string>> = [];
      let batchBytes = 0;
      for (const row of pending) {
        // Trailing newline is house convention for mirrored files; the mirror
        // standard is functional equivalence, not byte-identity with the
        // ledger (which stores no trailing newline).
        treeEntries.push({
          path: `${MIG_DIR}/${row.version}_${safeName(row.name)}.sql`,
          mode: "100644",
          type: "blob",
          content: `${row.sql_text}\n`,
        });
        batchBytes += row.bytes;
      }

      const newTree = await gh(token, `/repos/${GH_REPO}/git/trees`, {
        method: "POST",
        body: { base_tree: baseTree, tree: treeEntries },
      });

      const commit = await gh(token, `/repos/${GH_REPO}/git/commits`, {
        method: "POST",
        body: {
          message:
            `migration mirror: ${treeEntries.length} file(s) ` +
            `(${pending[0].version}..${pending[pending.length - 1].version})`,
          tree: newTree.sha,
          parents: [headSha],
        },
      });

      // force:false — if the branch moved underneath us GitHub rejects this and
      // nothing is published. The next batch re-reads head and retries.
      await gh(token, `/repos/${GH_REPO}/git/refs/heads/${branch}`, {
        method: "PATCH",
        body: { sha: commit.sha, force: false },
      });

      commits.push({ sha: commit.sha, files: treeEntries.length, bytes: batchBytes });
      written += treeEntries.length;

      // Deliberate pause between batches. GitHub's secondary limit is about
      // sustained write RATE, not total volume, so a short gap costs seconds
      // and buys a backfill that runs to completion.
      if (batch < maxBatches - 1) await sleep(1500);
    }

    // Re-read the gap after the run so the caller sees where things landed.
    if (mode !== "check" && !dryRun && written > 0) {
      const token2 = token;
      const ref = await gh(token2, `/repos/${GH_REPO}/git/ref/heads/${branch}`);
      const headCommit = await gh(token2, `/repos/${GH_REPO}/git/commits/${ref.object.sha}`);
      const { versions, fileCount } = await listMigrationVersions(token2, headCommit.tree.sha);
      const { data: after } = await sb.rpc("migration_mirror_stats", { p_have: versions });
      stats = {
        ledger_total: after?.[0]?.ledger_total ?? null,
        repo_versions: versions.length,
        repo_files: fileCount,
        pending: after?.[0]?.pending ?? null,
        pending_bytes: after?.[0]?.pending_bytes ?? null,
        branch,
        head: ref.object.sha,
      };
    }

    return jsonResponse({
      ok: true,
      mode,
      dry_run: dryRun,
      written,
      commits,
      stats,
      elapsed_ms: Date.now() - started,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await insertAlert({
      agencyId,
      alertType: "migration_mirror_failed",
      severity: "warning",
      title: "Migration mirror run failed",
      message: `${msg} (written this run: ${written})`,
      moduleReference: "migration-mirror",
    });
    return jsonResponse({ ok: false, error: msg, written, commits, stats }, 500);
  }
});
