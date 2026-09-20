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

import { sb } from "./supabase.ts";

// tasks_priority_check allows exactly these four. "urgent" is NOT one of them.
export type WatcherPriority = "low" | "medium" | "high" | "critical";

// tasks.task_category is a fixed check-constrained list. Anything outside it
// fails the insert.
export type WatcherCategory =
  | "web_app"
  | "admin"
  | "marketing"
  | "team_development"
  | "handbook"
  | "processes"
  | "finances";

export async function ensureWatcherTask(opts: {
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

export async function closeWatcherTask(opts: {
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
