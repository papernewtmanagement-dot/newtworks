// =========================================================================
// lib/composio.ts — document-processor-local shim over _shared/composio.ts
// =========================================================================
// Consolidated 2026-08-11. The HTTP request, timeout, and response-unwrapping
// logic used to be fully duplicated here (this file used to be ~150 lines
// mirroring _shared/composio.ts almost exactly, plus a hand-rolled
// writeTimeoutAlert). That duplication is why the 2026-08-06 timeout fix
// landed here first and took five more days to reach automation-runner. The
// mechanism now lives in exactly one place: _shared/composio.ts.
//
// WHY THIS FILE STILL EXISTS AT ALL: document-processor has always written an
// alerts-table row on EVERY timeout, unconditionally — that was the original
// fork's behavior since 2026-08-06. _shared/composio.ts makes alerting
// opt-in per call (alertTarget?), because other consumers (automation-runner)
// deliberately do NOT want a duplicate alerts-table row on top of their own
// automation_run_log + Telegram failure recording. Rather than touch this
// function's 30+ call sites to pass an alertTarget by hand, this shim
// supplies the same default the old duplicated implementation hardcoded, so
// deleting the duplication changed NOTHING about runtime alerting behavior.
// Every existing `callComposio(...)`, `callComposioNoAuth(...)` and
// `fetchWithTimeout(...)` call in this function keeps working with its
// existing arguments, unchanged.
// =========================================================================

import {
  callComposio as _sharedCallComposio,
  callComposioNoAuth as _sharedCallComposioNoAuth,
  fetchWithTimeout as _sharedFetchWithTimeout,
  type TimeoutAlertTarget,
} from "../../_shared/composio.ts";

// S3_FETCH_TIMEOUT_MS, COMPOSIO_TIMEOUT_MS and the ComposioCallResult type
// carry no document-processor-specific behavior — they are plain constants
// and a type, nothing to shim. Import them straight from _shared/composio.ts
// at the call sites that need them, not through here. (An earlier version of
// this file re-exported them, which is correct for the real multi-file
// source but breaks the bundle: the bundler strips the import line above and
// leaves a bare `export { S3_FETCH_TIMEOUT_MS };` standing next to the
// identical `export const S3_FETCH_TIMEOUT_MS` already declared by the
// _shared/composio.ts entry earlier in the bundle — two top-level exports of
// the same name, a boot failure esbuild caught and the project's own
// validator does not, since it only checks `const`, not `export {}`.)

function dpAlertTarget(service: string, context: string): TimeoutAlertTarget {
  return { moduleReference: `document-processor:${service}_timeout`, context };
}

export async function callComposio(
  opts: Parameters<typeof _sharedCallComposio>[0],
): ReturnType<typeof _sharedCallComposio> {
  return _sharedCallComposio({
    ...opts,
    alertTarget: opts.alertTarget ?? dpAlertTarget("composio", `tool=${opts.toolSlug}`),
  });
}

export async function callComposioNoAuth(
  opts: Parameters<typeof _sharedCallComposioNoAuth>[0],
): ReturnType<typeof _sharedCallComposioNoAuth> {
  return _sharedCallComposioNoAuth({
    ...opts,
    alertTarget: opts.alertTarget ?? dpAlertTarget("composio", `tool=${opts.toolSlug}`),
  });
}

export async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
  service: string,
  context: string,
): ReturnType<typeof _sharedFetchWithTimeout> {
  return _sharedFetchWithTimeout(url, init, timeoutMs, service, context, dpAlertTarget(service, context));
}
