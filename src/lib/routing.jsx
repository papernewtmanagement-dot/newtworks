// src/lib/routing.jsx
// Shared URL helpers + anchor-based ModuleLink component.
//
// Every clickable UI element that navigates to a top-level module MUST be
// rendered as an <a href="..."> so browsers expose the native "Open in new
// tab" affordance on right-click, cmd/ctrl-click, middle-click, and
// shift-click. See operational_rule "Newtworks nav elements are anchors,
// not buttons or divs".

// URL for a given app state. Inverse of parseUrl in NewtworksApp.jsx —
// keep the two in sync when the URL scheme changes.
//   dashboard              → "/"
//   cpr + weekDate         → "/cpr/YYYY-MM-DD"
//   any other module       → "/<moduleId>"
export function urlForState(moduleId, cprWeekDate) {
  if (cprWeekDate) return `/cpr/${cprWeekDate}`;
  if (moduleId === "dashboard") return "/";
  return `/${moduleId}`;
}

// Standard React-SPA click gate for an anchor whose default nav should
// stay SPA on a plain left-click but fall through to native browser
// behavior for modifier-clicks (cmd/ctrl/shift/alt) and middle-click,
// so right-click "Open in new tab" and cmd-click "Open in new tab"
// Just Work.
export function handleModuleLinkClick(e, callback) {
  if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
  e.preventDefault();
  if (typeof callback === "function") callback();
}

// Drop-in replacement for `<button onClick={()=>onNavigate("X")}>`.
// Renders as an <a> — right-click new-tab, cmd-click, middle-click all
// work natively. Plain left-click stays SPA (no page reload).
export function ModuleLink({ to, onNavigate, style, children, title, className }) {
  return (
    <a
      href={urlForState(to, null)}
      onClick={(e) => handleModuleLinkClick(e, () => onNavigate && onNavigate(to))}
      style={{ textDecoration: "none", color: "inherit", ...style }}
      title={title}
      className={className}
    >
      {children}
    </a>
  );
}
