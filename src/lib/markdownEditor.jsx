import { useRef } from "react";
import { T } from "./theme.js";

// ============================================================
// MARKDOWN LIST EDITING — shared by every manuals editor
//
// One place for "make this a bullet list" / "make this a numbered
// list" / indent / outdent, plus the keyboard behaviour people
// expect from any editor: Enter carries the list on, Enter on an
// empty item ends it, Tab and Shift+Tab move an item in and out.
//
// The helpers below are pure: they take the text and where the
// cursor is, and hand back new text and a new cursor position.
// MarkdownTextarea wires them to a real box with a small button
// row on top. Every manuals editor uses THIS component — do not
// hand-roll list buttons anywhere else.
//
// Syntax matches what src/lib/markdown.js actually renders:
//   "- item"     unordered
//   "1. item"    ordered
//   two leading spaces per level of nesting
// ============================================================

export const LIST_INDENT = "  ";

const UL_RE = /^(\s*)([-*])[ \t]+(.*)$/;
const OL_RE = /^(\s*)(\d+)\.[ \t]+(.*)$/;

// Read one line. Returns null when the line is not a list item.
export function parseListLine(line) {
  const u = UL_RE.exec(line || "");
  if (u) return { kind: "ul", indent: u[1], marker: u[2], number: null, text: u[3] };
  const o = OL_RE.exec(line || "");
  if (o) return { kind: "ol", indent: o[1], marker: null, number: parseInt(o[2], 10) || 1, text: o[3] };
  return null;
}

// Widen a selection out to whole lines, because list edits are per line.
export function lineBounds(value, selStart, selEnd) {
  const v = value || "";
  const start = v.lastIndexOf("\n", Math.max(0, selStart - 1)) + 1;
  const nl = v.indexOf("\n", selEnd);
  return { start, end: nl === -1 ? v.length : nl };
}

// When numbering a fresh block, carry on from the item directly above it.
function numberBefore(value, blockStart) {
  if (blockStart <= 0) return 0;
  const v = value || "";
  const prevEnd = blockStart - 1;
  const prevStart = v.lastIndexOf("\n", Math.max(0, prevEnd - 1)) + 1;
  const p = parseListLine(v.slice(prevStart, prevEnd));
  return p && p.kind === "ol" ? p.number : 0;
}

// Turn the selected lines into a list of `kind`, or strip the markers
// back off when every selected line is already that kind.
export function toggleList(value, selStart, selEnd, kind) {
  const v = value || "";
  const { start, end } = lineBounds(v, selStart, selEnd);
  const rows = v.slice(start, end).split("\n");
  const only = rows.length === 1;
  const targets = rows.filter((l) => l.trim() !== "");
  const stripping = targets.length > 0 && targets.every((l) => (parseListLine(l) || {}).kind === kind);

  let n = stripping || kind !== "ol" ? 0 : numberBefore(v, start);

  const out = rows.map((line) => {
    if (line.trim() === "" && !only) return line;
    const p = parseListLine(line);
    const indent = p ? p.indent : (/^(\s*)/.exec(line) || ["", ""])[1];
    const text = p ? p.text : line.trim();
    if (stripping) return indent + text;
    if (kind === "ul") return indent + "- " + text;
    n += 1;
    return indent + n + ". " + text;
  });

  const next = out.join("\n");
  return { value: v.slice(0, start) + next + v.slice(end), selStart: start, selEnd: start + next.length };
}

// Move the selected lines one level in (dir 1) or out (dir -1).
export function shiftIndent(value, selStart, selEnd, dir) {
  const v = value || "";
  const { start, end } = lineBounds(v, selStart, selEnd);
  const rows = v.slice(start, end).split("\n");
  const only = rows.length === 1;

  const out = rows.map((line) => {
    if (line.trim() === "" && !only) return line;
    if (dir > 0) return LIST_INDENT + line;
    const lead = (/^(\s*)/.exec(line) || ["", ""])[1];
    const cut = Math.min(LIST_INDENT.length, lead.length);
    return line.slice(cut);
  });

  const next = out.join("\n");
  return { value: v.slice(0, start) + next + v.slice(end), selStart: start, selEnd: start + next.length };
}

// Drop a horizontal line in as its own block. Markdown only reads three
// dashes as a line when they sit alone with a blank line either side, so
// the text around the cursor gets tidied to make room.
export function insertRule(value, selStart, selEnd) {
  const v = value || "";
  const { end } = lineBounds(v, selStart, selEnd);
  const before = v.slice(0, end).replace(/\s+$/, "");
  const after = v.slice(end).replace(/^\s+/, "");
  const head = before ? before + "\n\n" : "";
  const tail = after ? "\n\n" + after : "\n";
  const next = head + "---" + tail;
  const caret = head.length + 3 + (after ? 2 : 1);
  return { value: next, selStart: caret, selEnd: caret };
}

// Enter / Tab / Shift+Tab behaviour. Returns null to let the browser
// do its normal thing, which is the case on any line that is not a
// list item — Tab must still move focus for keyboard users.
export function handleListKey(e, value, selStart, selEnd) {
  const v = value || "";

  if (e.key === "Enter" && !e.shiftKey && selStart === selEnd) {
    const ls = v.lastIndexOf("\n", Math.max(0, selStart - 1)) + 1;
    const nl = v.indexOf("\n", selStart);
    const le = nl === -1 ? v.length : nl;
    const p = parseListLine(v.slice(ls, le));
    if (!p) return null;

    // Empty item: step out one level, or drop the marker and end the list.
    if (p.text.trim() === "") {
      if (p.indent.length >= LIST_INDENT.length) {
        const marker = p.kind === "ul" ? p.marker + " " : p.number + ". ";
        const line = p.indent.slice(LIST_INDENT.length) + marker;
        const caret = ls + line.length;
        return { value: v.slice(0, ls) + line + v.slice(le), selStart: caret, selEnd: caret };
      }
      return { value: v.slice(0, ls) + v.slice(le), selStart: ls, selEnd: ls };
    }

    const marker = p.kind === "ul" ? p.marker + " " : p.number + 1 + ". ";
    const ins = "\n" + p.indent + marker;
    const caret = selStart + ins.length;
    return { value: v.slice(0, selStart) + ins + v.slice(selEnd), selStart: caret, selEnd: caret };
  }

  if (e.key === "Tab") {
    const { start } = lineBounds(v, selStart, selEnd);
    const nl = v.indexOf("\n", start);
    const firstLine = v.slice(start, nl === -1 ? v.length : nl);
    if (!parseListLine(firstLine)) return null;
    return shiftIndent(v, selStart, selEnd, e.shiftKey ? -1 : 1);
  }

  return null;
}

const barStyle = {
  display: "flex", gap: 6, flexWrap: "wrap", marginBottom: 6,
};

const btnStyle = {
  padding: "5px 10px", borderRadius: 7, border: `1px solid ${T.slate300}`,
  background: T.white, color: T.slate700, fontSize: 12, fontWeight: 600,
  cursor: "pointer", lineHeight: 1.2, boxSizing: "border-box",
};

// The editing box every manuals editor uses.
// onChange receives an event-shaped object, so it drops straight into
// the same handlers a plain <textarea> was using.
export function MarkdownTextarea({ value, onChange, style, spellCheck = true, placeholder, id }) {
  const ref = useRef(null);

  const emit = (next) => {
    if (!next) return;
    onChange({ target: { value: next.value } });
    requestAnimationFrame(() => {
      const el = ref.current;
      if (!el) return;
      el.focus();
      try { el.setSelectionRange(next.selStart, next.selEnd); } catch (_) { /* older browsers */ }
    });
  };

  const act = (fn) => {
    const el = ref.current;
    if (!el) return;
    emit(fn(value || "", el.selectionStart || 0, el.selectionEnd || 0));
  };

  const onKeyDown = (e) => {
    const el = ref.current;
    if (!el) return;
    const next = handleListKey(e, value || "", el.selectionStart || 0, el.selectionEnd || 0);
    if (!next) return;
    e.preventDefault();
    emit(next);
  };

  return (
    <div>
      <div style={barStyle}>
        <button type="button" style={btnStyle} title="Bullet list" onClick={() => act((v, a, b) => toggleList(v, a, b, "ul"))}>• Bullets</button>
        <button type="button" style={btnStyle} title="Numbered list" onClick={() => act((v, a, b) => toggleList(v, a, b, "ol"))}>1. Numbers</button>
        <button type="button" style={btnStyle} title="Indent (Tab)" onClick={() => act((v, a, b) => shiftIndent(v, a, b, 1))}>→ Indent</button>
        <button type="button" style={btnStyle} title="Outdent (Shift+Tab)" onClick={() => act((v, a, b) => shiftIndent(v, a, b, -1))}>← Outdent</button>
        <button type="button" style={btnStyle} title="Horizontal line" onClick={() => act(insertRule)}>─ Line</button>
      </div>
      <textarea
        id={id}
        ref={ref}
        value={value}
        onChange={onChange}
        onKeyDown={onKeyDown}
        spellCheck={spellCheck}
        placeholder={placeholder}
        style={style}
      />
    </div>
  );
}

export default MarkdownTextarea;
