import { supabase, AGENCY_ID } from "./supabase.js";

// How every manual's content is loaded, one way for everyone. The manual pages
// (src/modules/Manual.jsx) and the Dashboard's Live tab both read the
// Processes manual through these, with the same who-sees-what rule, so the two
// can never be reading different scripts (Peter 2026-10-04: one source, no drift).

// What a manual page row carries. One list, so the manual and the Live tab
// always get the same row.
const PAGE_COLUMNS = "id, title, content, content_format, source_url, confluence_page_id, parent_page_id, sort_order, version, is_active, icon, divider_after, fetched_at, updated_at";

// Every live page of one manual that this person may see. `skip` leaves out
// pages by id; the Live tab skips the Daily Kickoff, a third of a megabyte that
// no call script pulls from.
export async function fetchManualPages(manualType, userRole, { skip = [] } = {}) {
  let q = supabase
    .from("manuals")
    .select(PAGE_COLUMNS)
    .eq("agency_id", AGENCY_ID)
    .eq("manual_type", manualType)
    .eq("is_active", true);
  for (const id of skip) q = q.neq("confluence_page_id", id);
  const { data, error } = await q;
  if (error) throw error;
  return filterBelowDivider(Array.isArray(data) ? data : [], userRole);
}

// The team-visibility gate. Admin users see every row; everyone else sees rows
// only up to and including the first root with divider_after=true. Everything
// after that root (in the sorted root list) plus all their descendants is
// filtered out. Root ordering matches the manual sidebar's, so this agrees
// with what the sidebar shows.
export const ADMIN_ROLES = ["owner", "admin"];
export function filterBelowDivider(rows, userRole) {
  if (!Array.isArray(rows) || rows.length === 0) return rows || [];
  if (ADMIN_ROLES.includes(userRole)) return rows;

  const byId = new Map(rows.map((r) => [r.confluence_page_id, r]));
  const roots = rows.filter(
    (r) => !r.parent_page_id || !byId.has(r.parent_page_id),
  );

  const cmp = (a, b) => {
    const ao = a?.sort_order;
    const bo = b?.sort_order;
    const aNull = ao == null;
    const bNull = bo == null;
    if (aNull && !bNull) return 1;
    if (!aNull && bNull) return -1;
    if (!aNull && !bNull && ao !== bo) return ao - bo;
    return (a?.title || "").localeCompare(b?.title || "");
  };
  const sortedRoots = [...roots].sort(cmp);

  const dividerIdx = sortedRoots.findIndex((r) => r?.divider_after);
  if (dividerIdx === -1) return rows;

  const belowLineRootIds = new Set(
    sortedRoots.slice(dividerIdx + 1).map((r) => r.confluence_page_id),
  );
  if (belowLineRootIds.size === 0) return rows;

  const childrenByParent = new Map();
  for (const r of rows) {
    if (!r.parent_page_id) continue;
    if (!childrenByParent.has(r.parent_page_id)) {
      childrenByParent.set(r.parent_page_id, []);
    }
    childrenByParent.get(r.parent_page_id).push(r.confluence_page_id);
  }
  const hiddenIds = new Set(belowLineRootIds);
  const queue = [...belowLineRootIds];
  while (queue.length) {
    const pid = queue.shift();
    const kids = childrenByParent.get(pid) || [];
    for (const kid of kids) {
      if (!hiddenIds.has(kid)) {
        hiddenIds.add(kid);
        queue.push(kid);
      }
    }
  }

  return rows.filter((r) => !hiddenIds.has(r.confluence_page_id));
}

// Named fragments (manual_type 'excerpt') that [Embedded excerpt from: X] markers pull in.
export async function fetchExcerptRows() {
  const { data, error } = await supabase
    .from("manuals")
    .select("id, title, content, is_active, version")
    .eq("agency_id", AGENCY_ID)
    .eq("manual_type", "excerpt")
    .eq("is_active", true);
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}

// Knowledge & FAQ rows that {{faq: topic_key}} markers pull in. buildFaqLookup
// (src/lib/markdown.js) keeps only approved, active rows.
export async function fetchFaqRows() {
  const { data, error } = await supabase
    .from("v_knowledge_faqs_resolved")
    .select("topic_key, question:question_resolved, answer:answer_resolved, tag_label, product_line, sort_order, status, is_active")
    .eq("agency_id", AGENCY_ID);
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}
