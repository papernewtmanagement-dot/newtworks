import { T } from "./theme.js";

// src/lib/TreeRow.jsx
//
// One child row under a parent, drawn with file-list lines (Peter 2026-09-21):
// a line comes down from the parent and turns right into each row; the last
// row's line stops at the turn. The change log hangs a customer's records off
// the customer this way, and the Backfill tab hangs a household's products off
// the household.
//
// mid = pixels from the top of the row to the middle of its first line, so the
// turn lands on the text. The change log's 12px text at 1.5 line height is 9;
// a Backfill product row (28px tall) is 14.
export function TreeRow({ last = false, mid = 9, indent = 18, children, style }) {
  const line = T.slate300;
  return (
    <div style={{ position: "relative", paddingLeft: indent, ...style }}>
      <span aria-hidden="true" style={{
        position: "absolute", left: 5, top: 0,
        height: last ? mid : "100%", borderLeft: `1px solid ${line}`,
      }} />
      <span aria-hidden="true" style={{
        position: "absolute", left: 5, top: mid, width: indent - 9, borderTop: `1px solid ${line}`,
      }} />
      {children}
    </div>
  );
}
