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

import { getSetting, jsonResponse, AGENCY_ID_DEFAULT, sb } from "../_shared/supabase.ts";
import { requireSharedSecret } from "../_shared/auth.ts";
import { insertAlert } from "../_shared/alerts.ts";

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

    // --- prune: delete repo files that are provably redundant --------------
    if (mode === "prune") {
      const ref = await gh(token, `/repos/${GH_REPO}/git/ref/heads/${branch}`);
      const headSha: string = ref.object.sha;
      const headCommit = await gh(token, `/repos/${GH_REPO}/git/commits/${headSha}`);
      const baseTree: string = headCommit.tree.sha;
      const files = await listMigrationFiles(token, baseTree);
      const present = new Set(files.map((f) => f.path));

      const { data: prunable, error: prErr } = await sb.rpc("migration_mirror_prunable", {
        p_agency_id: agencyId,
      });
      if (prErr) throw new Error(`migration_mirror_prunable failed: ${prErr.message}`);

      // Only delete what is actually in the tree right now.
      const paths = (prunable ?? [])
        .map((p: any) => p.repo_path)
        .filter((p: string) => present.has(p));

      const take = Math.min(Math.max(Number(body.prune_limit ?? 700), 1), 900);
      const chunkSize = Math.min(Math.max(Number(body.prune_chunk ?? 100), 1), 200);
      const slice = paths.slice(0, take);

      if (dryRun || slice.length === 0) {
        return jsonResponse({
          ok: true, mode: "prune", dry_run: dryRun,
          prunable: (prunable ?? []).length,
          present_in_tree: paths.length,
          would_delete: slice.length,
          elapsed_ms: Date.now() - started,
        });
      }

      // One tree call carrying 658 deletions returns 422 GitRPC::BadObjectState.
      // The entry shape is correct (it matches the proven commit script); the
      // volume is what GitHub rejects. Delete in chunks, each its own commit,
      // re-reading the branch head every time so a concurrent push cannot be
      // clobbered.
      const pruneCommits: Array<{ sha: string; files: number }> = [];
      let deleted = 0;
      for (let i = 0; i < slice.length; i += chunkSize) {
        const chunk = slice.slice(i, i + chunkSize);

        const curRef = await gh(token, `/repos/${GH_REPO}/git/ref/heads/${branch}`);
        const curSha: string = curRef.object.sha;
        const curCommit = await gh(token, `/repos/${GH_REPO}/git/commits/${curSha}`);

        const t = await gh(token, `/repos/${GH_REPO}/git/trees`, {
          method: "POST",
          body: {
            base_tree: curCommit.tree.sha,
            tree: chunk.map((p: string) => ({ path: p, mode: "100644", type: "blob", sha: null })),
          },
        });

        const c = await gh(token, `/repos/${GH_REPO}/git/commits`, {
          method: "POST",
          body: {
            message: `migration mirror: prune ${chunk.length} redundant migration file(s)`,
            tree: t.sha,
            parents: [curSha],
          },
        });

        await gh(token, `/repos/${GH_REPO}/git/refs/heads/${branch}`, {
          method: "PATCH",
          body: { sha: c.sha, force: false },
        });

        pruneCommits.push({ sha: c.sha, files: chunk.length });
        deleted += chunk.length;
        await sleep(1200);
      }

      return jsonResponse({
        ok: true, mode: "prune", dry_run: false,
        prunable: (prunable ?? []).length,
        deleted,
        commits: pruneCommits,
        elapsed_ms: Date.now() - started,
      });
    }

    // --- adopt: register repo files whose SQL is nowhere in the ledger ------
    if (mode === "adopt") {
      const ref = await gh(token, `/repos/${GH_REPO}/git/ref/heads/${branch}`);
      const headCommit = await gh(token, `/repos/${GH_REPO}/git/commits/${ref.object.sha}`);
      const files = await listMigrationFiles(token, headCommit.tree.sha);
      const shaByPath = new Map(files.map((f) => [f.path, f.sha]));

      // The audit already decided which files have no ledger counterpart.
      const { data: unmatched, error: unErr } = await sb
        .from("migration_mirror_audit")
        .select("repo_version, repo_path")
        .eq("agency_id", agencyId)
        .is("ledger_match_version", null)
        .order("repo_path");
      if (unErr) throw new Error(`audit read failed: ${unErr.message}`);

      const offset = Math.max(Number(body.offset ?? 0), 0);
      const take = Math.min(Math.max(Number(body.adopt_limit ?? 100), 1), 250);
      const slice = (unmatched ?? []).slice(offset, offset + take);

      const rows: Array<{ version: string; name: string; sql_text: string }> = [];
      const missing: string[] = [];
      for (let i = 0; i < slice.length; i += 8) {
        const win = slice.slice(i, i + 8);
        const done = await Promise.all(win.map(async (u: any) => {
          const blobSha = shaByPath.get(u.repo_path);
          if (!blobSha) return { missing: u.repo_path };
          const blob = await gh(token, `/repos/${GH_REPO}/git/blobs/${blobSha}`);
          const raw = new TextDecoder().decode(
            Uint8Array.from(atob(blob.content.replace(/\n/g, "")), (c) => c.charCodeAt(0)),
          );
          // Filename is <14-digit version>_<name>.sql — recover the name part.
          const base = u.repo_path.split("/").pop() ?? "";
          const name = base.replace(/^\d{14}_?/, "").replace(/\.sql$/i, "") || "adopted";
          return { row: { version: u.repo_version, name, sql_text: raw.replace(/\n$/, "") } };
        }));
        for (const d of done) {
          if ((d as any).missing) missing.push((d as any).missing);
          else rows.push((d as any).row);
        }
      }

      let result: any = null;
      if (rows.length && !dryRun) {
        const { data: ad, error: adErr } = await sb.rpc("migration_mirror_adopt", { p_rows: rows });
        if (adErr) throw new Error(`migration_mirror_adopt failed: ${adErr.message}`);
        result = ad?.[0] ?? null;
      }

      return jsonResponse({
        ok: true,
        mode: "adopt",
        dry_run: dryRun,
        candidates: (unmatched ?? []).length,
        offset,
        prepared: rows.length,
        missing_in_tree: missing,
        result,
        next_offset: offset + slice.length < (unmatched ?? []).length ? offset + slice.length : null,
        elapsed_ms: Date.now() - started,
      });
    }

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

      // Blob fetches are I/O bound. Doing 300 of them one after another burns
      // the worker's wall clock and returns WORKER_RESOURCE_LIMIT. A modest
      // concurrency window keeps the same total work well inside budget.
      const CONCURRENCY = 8;
      const rows: Array<{ version: string; path: string; fingerprint: string }> = [];
      for (let i = 0; i < slice.length; i += CONCURRENCY) {
        const window = slice.slice(i, i + CONCURRENCY);
        const done = await Promise.all(window.map(async (t) => {
          const blob = await gh(token, `/repos/${GH_REPO}/git/blobs/${t.sha}`);
          const raw = blob.encoding === "base64"
            ? new TextDecoder().decode(
                Uint8Array.from(atob(blob.content.replace(/\n/g, "")), (c) => c.charCodeAt(0)),
              )
            : String(blob.content ?? "");
          return { version: t.version, path: t.path, fingerprint: await fingerprint(raw) };
        }));
        rows.push(...done);
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

    // Heartbeat. A dispatch rejected at the gateway (verify_jwt momentarily
    // true during a redeploy) never reaches this code and cannot alert about
    // itself, so absence of a row here is what the nightly handler's 26h
    // staleness check looks for. Never let a logging failure fail the run.
    try {
      await sb.from("migration_mirror_runs").insert({
        agency_id: agencyId,
        mode,
        written,
        pending_after: stats?.pending ?? null,
        ok: true,
      });
    } catch (_e) { /* heartbeat is best-effort */ }

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
