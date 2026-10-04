import { supabase, AGENCY_ID } from "./supabase.js";

// The shared pieces every manual page can pull in, loaded one way for everyone.
// The manual pages (src/modules/Manual.jsx) and the Dashboard's Live tab both
// read scripts through these, so a change to what is loaded happens once.

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

// The Processes manual pages the Live tab walks: FIT Conversations, Retention,
// and everything [Included from: X] can reach. The Daily Kickoff is left out;
// it is a third of a megabyte and no call script pulls from it.
export async function fetchScriptPages() {
  const { data, error } = await supabase
    .from("manuals")
    .select("id, title, content, confluence_page_id, parent_page_id, sort_order, is_active")
    .eq("agency_id", AGENCY_ID)
    .eq("manual_type", "processes")
    .eq("is_active", true)
    .neq("confluence_page_id", "daily-kickoff");
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}
