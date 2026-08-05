// =========================================================================
// _shared/html.ts
// =========================================================================
// Tiny HTML helpers shared across the email-composing edge functions.
// Formatting helpers (money, dates) stay LOCAL to each function on purpose —
// their formats genuinely differ per surface and unifying them would change
// live email output.
// =========================================================================

export function escHtml(s: string | null | undefined): string {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
