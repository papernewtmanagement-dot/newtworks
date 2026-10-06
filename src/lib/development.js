import { supabase } from "./supabase.js";

// =========================================================================
// development.js
// =========================================================================
// Development > Ongoing: what one person has due right now — licenses and
// CE, the handbook, and their part of a new hire's onboarding plan. The
// database function development_ongoing() decides what is on it; the
// Ongoing card, the yellow bar and Peter's sidebar all read that one rule.
// =========================================================================

// Sent on the window whenever something on Development changes (a form sent,
// a line ticked, a license marked done), so the card and the bar look again.
export const DEVELOPMENT_CHANGED = "newtworks:development-changed";

export function developmentChanged() {
  if (typeof window !== "undefined") window.dispatchEvent(new Event(DEVELOPMENT_CHANGED));
}

// The one call for a person's Ongoing items. An empty list on any failure,
// so a hiccup never paints a false alarm.
export async function loadOngoing(teamMemberId) {
  if (!supabase || !teamMemberId) return [];
  const { data, error } = await supabase.rpc("development_ongoing", { p_team_member_id: teamMemberId });
  if (error) return [];
  return Array.isArray(data) ? data : [];
}
