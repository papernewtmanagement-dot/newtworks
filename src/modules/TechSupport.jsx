import Playbook from "./Playbook.jsx";

// ============================================================
// BCC TECH SUPPORT MODULE
// Thin wrapper — delegates to Playbook module with mode="techsupport".
// Playbook.jsx branches on `mode` for URL basePath, tree_root filter,
// title/subtitle labels, and empty/error text.
// Content lives in the same public.playbook table under
// tree_root='Tech Support'.
// ============================================================

export default function TechSupport() {
  return <Playbook mode="techsupport" />;
}
