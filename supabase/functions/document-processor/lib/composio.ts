// =========================================================================
// lib/composio.ts
// =========================================================================
// Composio HTTP wrapper. Mirrors callComposio() from automation-runner so
// behavior stays identical — same auth shape, same response unwrapping.
//
// TIMEOUT HANDLING added 2026-08-06 (Task 4, build-instructions 2026-08-06).
// Two document-processor invocations hung ~105-113s then died as an
// uncaught exception (Supabase status 546) rather than a clean error --
// the signature of an external call stuck until the platform's own
// wall-clock limit killed the whole function. Every fetch() here now has
// an explicit timeout well below that limit, so a stuck call fails fast
// and CATCHABLY instead of taking the whole invocation down with it. On
// timeout: write an alerts row (service, elapsed ms, tool/context) and
// return a normal {ok:false} result -- never let it surface as an
// uncaught exception. No retry logic added here on purpose: retrying a
// hang just doubles the wait and can push an otherwise-fine invocation
// over the platform limit too. Retry is a separate decision.
// =========================================================================

import { sb } from "./supabase.ts";

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";
const COMPOSIO_TIMEOUT_MS = 25000;
export const S3_FETCH_TIMEOUT_MS = 25000;

export async function writeTimeoutAlert(service: string, elapsedMs: number, context: string): Promise<void> {
  try {
    await sb.from("alerts").insert({
      alert_type: "external_call_timeout",
      severity: "warning",
      title: `${service} call timed out`,
      message: `${service} call did not respond within ${elapsedMs}ms and was aborted. Context: ${context}`,
      module_reference: `document-processor:${service}_timeout`,
      is_read: false,
      is_resolved: false,
    });
  } catch (_e) {
    // Alert-writing is best-effort. Never let a failed alert insert mask
    // the original timeout or throw a second uncaught exception.
  }
}

export async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
  service: string,
  context: string,
): Promise<{ res: Response | null; timedOut: boolean; elapsedMs: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();
  try {
    const res = await fetch(url, { ...init, signal: controller.signal });
    return { res, timedOut: false, elapsedMs: Date.now() - startedAt };
  } catch (e) {
    const elapsedMs = Date.now() - startedAt;
    const timedOut = e instanceof Error && e.name === "AbortError";
    if (timedOut) await writeTimeoutAlert(service, elapsedMs, context);
    return { res: null, timedOut, elapsedMs };
  } finally {
    clearTimeout(timer);
  }
}

export interface ComposioCallResult {
  ok: boolean;
  data: any;
  error: string | null;
  httpStatus: number;
}

export async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
  /**
   * Which published set of tools to use. LEAVE THIS UNSET unless you have a
   * reason not to.
   *
   * Composio publishes its tools in dated sets. A request that does not name a
   * set gets the oldest one, which holds far fewer tools than the account
   * actually has — 51 Google Drive tools instead of 90. Anything missing from
   * that oldest set answers "Tool ... not found", which reads exactly like a
   * permission problem and is not one. Two months of Drive filing and every
   * scanned resume were lost to this, and four rounds of fixing went at the
   * wrong layer, because a tool tested by hand goes through a connection that
   * DOES name a set and therefore always worked.
   *
   * It is set per request on purpose. Naming a newer set changes the shape of
   * what comes back, and the payroll, bank statement and comp parsers all read
   * those shapes. So each caller opts in where it has been checked, rather than
   * one flip changing everything at once.
   */
  toolkitVersion?: string;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await fetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        connected_account_id: opts.connectedAccountId,
        arguments: opts.toolArguments,
        ...(opts.toolkitVersion ? { version: opts.toolkitVersion } : {}),
      }),
    },
    COMPOSIO_TIMEOUT_MS,
    "composio",
    `tool=${opts.toolSlug}`,
  );
  if (!res) {
    const error = timedOut
      ? `Composio call timed out after ${elapsedMs}ms (tool: ${opts.toolSlug})`
      : `Composio fetch failed (tool: ${opts.toolSlug})`;
    return { ok: false, data: null, error, httpStatus: 0 };
  }
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}

export async function callComposioNoAuth(opts: {
  apiKey: string;
  userId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await fetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        arguments: opts.toolArguments,
      }),
    },
    COMPOSIO_TIMEOUT_MS,
    "composio",
    `tool=${opts.toolSlug}`,
  );
  if (!res) {
    const error = timedOut
      ? `Composio call timed out after ${elapsedMs}ms (tool: ${opts.toolSlug})`
      : `Composio fetch failed (tool: ${opts.toolSlug})`;
    return { ok: false, data: null, error, httpStatus: 0 };
  }
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}
