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
// Each entry in `changes` is one of two shapes:
//   a field that moved:  { field, label, before, after, count }
//   a named event:       { event: true, field, label, after, tone, count }
// Events come first. change_items names them (Peter 2026-09-21): "Policy
// issued" instead of issued date and issued premium going blank -> value,
// "Sale removed" instead of a status flip, and so on. `after` on an event is
// its detail and can be empty. count is above 1 only when one click made the
// same move on several records.

import { T } from "./theme.js";

export function changeDiffList(changes) {
  return Array.isArray(changes) ? changes.filter(c => c && c.label) : [];
}

const TONE = { green: T.green, red: T.red, amber: T.amber };
export function changeTone(c) { return (c && TONE[c.tone]) || T.slate800; }
export function changeEvents(changes) { return changeDiffList(changes).filter(c => c.event); }

function Pair({ c, muted, detailOnly }) {
  if (c.event) {
    if (detailOnly) {
      if (!c.after) return null;
      return <span>{c.after}{Number(c.count) > 1 ? <span style={{ color: muted }}>{` ×${c.count}`}</span> : null}</span>;
    }
    return (
      <>
        <span style={{ fontWeight: 700, color: changeTone(c) }}>{c.label}</span>
        {c.after ? <span>{`: ${c.after}`}</span> : null}
        {Number(c.count) > 1 ? <span style={{ color: muted }}>{` ×${c.count}`}</span> : null}
      </>
    );
  }
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
// eventsAsDetail → the event names are already shown elsewhere on the row, so
// an event draws only its detail, and an event with no detail draws nothing.
export function ChangeDiffs({ changes, inline = false, muted = T.slate500, eventsAsDetail = false }) {
  const list = changeDiffList(changes).filter(c => !(eventsAsDetail && c.event && !c.after));
  if (!list.length) return null;
  if (inline) {
    return (
      <span>
        <span style={{ color: muted }}>{" ("}</span>
        {list.map((c, i) => (
          <span key={c.field + i}>
            {i > 0 ? <span style={{ color: muted }}>{"; "}</span> : null}
            <Pair c={c} muted={muted} detailOnly={eventsAsDetail} />
          </span>
        ))}
        <span style={{ color: muted }}>{")"}</span>
      </span>
    );
  }
  return <>{list.map((c, i) => <div key={c.field + i}><Pair c={c} muted={muted} detailOnly={eventsAsDetail} /></div>)}</>;
}
