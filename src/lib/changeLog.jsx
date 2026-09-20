// src/lib/changeLog.jsx
//
// One place to draw the before and after on a change record (Peter 2026-09-19).
//
// Nothing here decides what a field is called or how a value reads. The
// database does all of that: change_field_label gives the plain-English name,
// change_field_hidden drops the bookkeeping columns, change_value_text turns a
// stored value into something readable, and change_diff puts the three
// together. production_changes_for_range and change_log_recent both return the
// result as a `changes` column, so the Activity Log day view, the Activity Log
// full history and the CPR Log Changes box all read the same pairs and can
// never disagree about what moved.
//
// Each entry in `changes`:
//   { field, label, before, after, count }
// count is above 1 only when one click made the same move on several records.

import { T } from "./theme.js";

export function changeDiffList(changes) {
  return Array.isArray(changes) ? changes.filter(c => c && c.label) : [];
}

function Pair({ c, muted }) {
  return (
    <>
      <span style={{ color: muted }}>{c.label}:</span>{" "}
      <span>{c.before}</span>
      <span style={{ color: muted }}> → </span>
      <span>{c.after}</span>
      {Number(c.count) > 1 ? <span style={{ color: muted }}>{` ×${c.count}`}</span> : null}
    </>
  );
}

// inline=false → one pair per line, for a table cell with room.
// inline=true  → all pairs in brackets on the end of a sentence.
export function ChangeDiffs({ changes, inline = false, muted = T.slate500 }) {
  const list = changeDiffList(changes);
  if (!list.length) return null;
  if (inline) {
    return (
      <span>
        <span style={{ color: muted }}>{" ("}</span>
        {list.map((c, i) => (
          <span key={c.field + i}>
            {i > 0 ? <span style={{ color: muted }}>{"; "}</span> : null}
            <Pair c={c} muted={muted} />
          </span>
        ))}
        <span style={{ color: muted }}>{")"}</span>
      </span>
    );
  }
  return <>{list.map((c, i) => <div key={c.field + i}><Pair c={c} muted={muted} /></div>)}</>;
}
