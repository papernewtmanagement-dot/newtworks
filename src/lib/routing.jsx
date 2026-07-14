// src/lib/routing.jsx
// Shared URL helpers + anchor-based ModuleLink component + useTabParam hook.
//
// Every clickable UI element that navigates to a top-level module MUST be
// rendered as an <a href="..."> so browsers expose the native "Open in new
// tab" affordance on right-click, cmd/ctrl-click, middle-click, and
// shift-click. See operational_rule "Newtworks nav elements are anchors,
// not buttons or divs".

import { useState, useEffect, useCallback } from "react";

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

// ─── useTabParam ───────────────────────────────────────────────────────────
// Persist a tab identifier in the URL query string so a page refresh restores
// the same tab. Drop-in replacement for `useState(defaultValue)` in any
// module whose top of the render tree already tracks a "which tab is showing"
// piece of state.
//
// Usage (single-tab module):
//   const [tab, setTab] = useTabParam("tab", "overview");
//
// Usage with an allowlist (recommended — guards against stale cross-module
// URL params leaking in during SPA navigation):
//   const [tab, setTab] = useTabParam("tab", "overview",
//     ["overview","refrev","sources","spend","economics","everquote","ideas"]);
//
// Semantics:
//   - Initial value: `paramName` query value if present AND (no allowlist OR
//     value is in the allowlist); otherwise `defaultValue`.
//   - setTab writes the URL via history.replaceState. Refresh restores the
//     tab; browser back button does NOT step through tab changes (which is
//     what we want — tabs are not navigations).
//   - Setting the tab to `defaultValue` REMOVES the param, keeping URLs
//     clean when a module is on its default tab.
//   - popstate updates the state so URL edits from elsewhere (back button
//     across modules, external link paste) stay in sync.
//   - Multiple tab groups on one page can coexist by passing distinct
//     `paramName`s (e.g. "tab" and "subtab").
function _readParam(name) {
  if (typeof window === "undefined") return null;
  try {
    return new URLSearchParams(window.location.search).get(name);
  } catch {
    return null;
  }
}

function _isValid(value, validValues) {
  if (value === null || value === undefined) return false;
  if (!Array.isArray(validValues) || validValues.length === 0) return true;
  return validValues.includes(value);
}

export function useTabParam(paramName, defaultValue, validValues) {
  const [tab, setTabState] = useState(() => {
    const v = _readParam(paramName);
    return _isValid(v, validValues) ? v : defaultValue;
  });

  useEffect(() => {
    const onPop = () => {
      const v = _readParam(paramName);
      setTabState(_isValid(v, validValues) ? v : defaultValue);
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paramName, defaultValue, Array.isArray(validValues) ? validValues.join("|") : ""]);

  const setTab = useCallback((next) => {
    setTabState(next);
    if (typeof window === "undefined") return;
    try {
      const sp = new URLSearchParams(window.location.search);
      if (next === defaultValue || next === null || next === undefined) {
        sp.delete(paramName);
      } else {
        sp.set(paramName, String(next));
      }
      const qs = sp.toString();
      const path = window.location.pathname;
      const hash = window.location.hash || "";
      const newUrl = qs ? `${path}?${qs}${hash}` : `${path}${hash}`;
      window.history.replaceState({}, "", newUrl);
    } catch {
      // no-op if URL API unavailable
    }
  }, [paramName, defaultValue]);

  return [tab, setTab];
}
