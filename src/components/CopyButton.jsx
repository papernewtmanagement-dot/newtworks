import { useState, useEffect, useRef } from "react";
import { T } from "../lib/theme.js";

// ─── Copy to clipboard ────────────────────────────────────────
// One copy control for the whole app. The small grey icon on a table row and
// the labeled button that is a page's main copy action are the same component,
// so the clipboard handling, the confirmation tick and the failure state only
// exist in one place.
//
// Props:
//   value    — what goes on the clipboard. A string, or a function that returns
//              one. The function may be slow and may await, for the cases that
//              have to build or fetch the text first (minting a link, putting a
//              prompt together). If it throws, the button shows the failure.
//   label    — optional text. Leave it off for the bare icon.
//   variant  — "icon" (default), "soft" (grey pill), "primary" (blue block).
//   full     — stretch a labeled button across its container.
//   title    — tooltip and screen-reader text. Falls back to the label.
//   size     — icon size in pixels. Defaults to 11 bare, 14 with a label.
//   disabled — greys it out and blocks the click.
//   busyText / doneText / errorText — labeled wording per state.

export async function copyText(value) {
  const text = value === null || value === undefined ? "" : String(value);
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Permission denied or no secure context — fall through to the old path.
  }
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.position = "fixed";
    ta.style.top = "0";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(ta);
    return ok;
  } catch {
    return false;
  }
}

export default function CopyButton({
  value,
  label,
  variant = "icon",
  full = false,
  title,
  size,
  disabled = false,
  busyText = "Copying…",
  doneText = "Copied",
  errorText = "Copy failed",
}) {
  const [state, setState] = useState("idle");   // idle | busy | done | error
  const timer = useRef(null);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; if (timer.current) clearTimeout(timer.current); }, []);

  const settle = (next, ms) => {
    if (!alive.current) return;
    setState(next);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => { if (alive.current) setState("idle"); }, ms);
  };

  const onClick = async (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (disabled || state === "busy") return;
    try {
      let text = value;
      if (typeof value === "function") {
        setState("busy");
        text = await value();
      }
      // Nothing to copy is not a failure — the caller just is not ready yet.
      if (text === null || text === undefined || text === "") { setState("idle"); return; }
      const ok = await copyText(text);
      settle(ok ? "done" : "error", ok ? 1800 : 2500);
    } catch {
      settle("error", 2500);
    }
  };

  const px = size || (label ? 14 : 11);
  const svg = {
    width: px, height: px, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
    strokeLinecap: "round", strokeLinejoin: "round", style: { display: "block", flexShrink: 0 },
  };
  const icon = state === "done"
    ? <svg {...svg} strokeWidth="3"><path d="M20 6 9 17l-5-5" /></svg>
    : state === "error"
      ? <svg {...svg} strokeWidth="3"><path d="M18 6 6 18" /><path d="m6 6 12 12" /></svg>
      : <svg {...svg} strokeWidth="2.2"><rect x="9" y="9" width="12" height="12" rx="2" /><path d="M5 15V5a2 2 0 0 1 2-2h10" /></svg>;

  const text = !label ? null
    : state === "busy" ? busyText
    : state === "done" ? doneText
    : state === "error" ? errorText
    : label;

  const base = {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: label ? 7 : 0,
    cursor: disabled ? "not-allowed" : state === "busy" ? "wait" : "pointer",
    flexShrink: 0,
    boxSizing: "border-box",
    fontFamily: "inherit",
  };

  let skin;
  if (variant === "primary") {
    const bg = disabled ? T.slate300 : state === "done" ? T.green : state === "error" ? T.red : T.blue;
    skin = { padding: "12px", fontSize: 13, fontWeight: 700, color: T.white, background: bg, border: "none", borderRadius: 10, width: full ? "100%" : undefined };
  } else if (variant === "soft") {
    const done = state === "done" || state === "error";
    skin = {
      padding: "7px 14px", fontSize: 12, fontWeight: 600,
      color: done ? T.white : disabled ? T.slate400 : T.slate700,
      background: state === "done" ? T.green : state === "error" ? T.red : T.slate100,
      border: "none", borderRadius: 7, width: full ? "100%" : undefined,
    };
  } else {
    skin = {
      padding: 0, marginLeft: 5, background: "none", border: "none",
      color: state === "done" ? T.green : state === "error" ? T.red : T.slate400,
    };
  }

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      title={title || label || "Copy"}
      aria-label={title || label || "Copy"}
      style={{ ...base, ...skin }}
    >
      {icon}
      {text}
    </button>
  );
}
