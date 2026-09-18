import { useState, useEffect, useRef } from "react";
import { T } from "../lib/theme.js";

// ─── Copy to clipboard ────────────────────────────────────────
// One small icon button for the whole app. Click it and the value lands on
// the clipboard; the icon turns into a check mark for a moment so the click
// is visibly confirmed.
//
// Props:
//   value — what goes on the clipboard. Numbers are turned into text.
//   title — tooltip and screen-reader label. Default "Copy".
//   size  — icon size in pixels. Default 11, which sits inside 12px table text.
//
// The glyph is a drawn shape rather than an emoji so it stays one quiet grey
// and does not shout on a row that already carries a name and three numbers.

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

export default function CopyButton({ value, title = "Copy", size = 11 }) {
  const [done, setDone] = useState(false);
  const timer = useRef(null);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  const onClick = async (e) => {
    e.preventDefault();
    e.stopPropagation();
    const ok = await copyText(value);
    if (!ok) return;
    setDone(true);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setDone(false), 1200);
  };

  const svg = { width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeLinecap: "round", strokeLinejoin: "round", style: { display: "block" } };

  return (
    <button
      type="button"
      onClick={onClick}
      title={title}
      aria-label={title}
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        background: "none",
        border: "none",
        padding: 0,
        marginLeft: 5,
        cursor: "pointer",
        color: done ? T.green : T.slate400,
        flexShrink: 0,
        boxSizing: "border-box",
      }}
    >
      {done ? (
        <svg {...svg} strokeWidth="3"><path d="M20 6 9 17l-5-5" /></svg>
      ) : (
        <svg {...svg} strokeWidth="2.2"><rect x="9" y="9" width="12" height="12" rx="2" /><path d="M5 15V5a2 2 0 0 1 2-2h10" /></svg>
      )}
    </button>
  );
}
