// src/lib/changeLog.jsx
//
// One place to draw a change record (Peter 2026-09-19, reworked 2026-09-21).
// The Activity Log Changes tab and the CPR both draw with these, so the two
// read the same way.
//
// Nothing here decides what a field is called or how a value reads. The
// database does all of that: change_items names the events and hands every
// other field to change_diff (change_field_label, change_field_hidden,
// change_value_text). production_changes_for_range and change_log_recent both
// return the result as a `changes` column.
//
// Each entry in `changes` is one of two shapes:
//   a field that moved:  { field, label, before, after, count }
//   a named event:       { event: true, field, label, after, tone, count }
// Events come first. "Policy issued" instead of issued date and issued premium
// going blank -> value, "Sale removed" instead of a status flip, "ECRM link
// added" instead of the whole address. `after` on an event is its detail and
// can be empty. count is above 1 only when one click made the same move on
// several records.
//
// production_changes_for_range rows come in three kinds (Peter 2026-09-21):
//   kind "change" — one click's edits or removals. ChangeEntry draws it.
//   kind "issue"  — one policy issued, marked not issued, or its issue
//                   corrected. `policy` carries the issue date, the issued
//                   premium and how far it is from the submitted premium.
//                   IssueEntry draws it.
//   kind "spot_check" — a spot-check note someone left on an entry. SpotEntry
//                   draws it.
// They are kept apart on screen: a toggle on the Changes tab, separate cards
// on the CPR. The customer name opens the household popup wherever the page
// provides one (the Activity Log does; the CPR shows plain text).

import { T } from "./theme.js";
import { CustomerName } from "./customerAccount.jsx";

const TONE = { green: T.green, red: T.red, amber: T.amber, slate: T.slate600 };
export function changeTone(c) { return (c && TONE[c.tone]) || T.slate800; }

export function changeDiffList(changes) {
  return Array.isArray(changes) ? changes.filter(c => c && c.label) : [];
}
export function changeEvents(changes) { return changeDiffList(changes).filter(c => c.event); }

// The entries that belong on the issued-policies side rather than with edits.
const ISSUE_FIELDS = new Set(["event:issued", "event:unissued", "event:issued_premium", "issued_date", "issued_premium"]);
export function isIssueItem(c) { return !!(c && ISSUE_FIELDS.has(c.field)); }
export function isSpotItem(c) { return !!(c && c.field === "spot_check_note"); }
// Which side of the toggle one entry of `changes` belongs on.
export function changeItemKind(c) { return isIssueItem(c) ? "issue" : isSpotItem(c) ? "spot_check" : "change"; }

function Customer({ r }) {
  if (!r.subject) return null;
  return <CustomerName label={r.subject} phone4={r.phone_last4} style={{ fontWeight: 600 }} />;
}

// The timestamp on every change line: bold and in the accent color so the eye
// can run down the times.
export function changeWhenText(ts, withDay = false) {
  if (!ts) return "";
  const d = new Date(ts);
  if (!Number.isFinite(d.getTime())) return "";
  return d.toLocaleString("en-US", {
    timeZone: "America/Chicago",
    ...(withDay ? { weekday: "short", month: "numeric", day: "numeric" } : {}),
    hour: "numeric", minute: "2-digit",
  });
}
export function ChangeStamp({ ts, withDay = false }) {
  return <span style={{ fontWeight: 700, color: T.blue, whiteSpace: "nowrap" }}>{changeWhenText(ts, withDay)}</span>;
}

function Pair({ c, muted, detailOnly }) {
  const times = Number(c.count) > 1 ? <span style={{ color: muted }}>{` ×${c.count}`}</span> : null;
  if (c.event) {
    if (detailOnly) {
      if (!c.after) return null;
      return <span>{c.field === "event:removed" ? `reason: ${c.after}` : c.after}{times}</span>;
    }
    return (
      <>
        <span style={{ fontWeight: 700, color: changeTone(c) }}>{c.label}</span>
        {c.after ? <span>{`: ${c.after}`}</span> : null}
        {times}
      </>
    );
  }
  return (
    <>
      <span style={{ color: muted }}>{c.label}:</span>{" "}
      <span>{c.before}</span>
      <span style={{ color: muted }}> → </span>
      <span>{c.after}</span>
      {times}
    </>
  );
}

// inline=false → one pair per line, for a table cell with room.
// inline=true  → all pairs in brackets on the end of a sentence.
// eventsAsDetail → the event names are shown elsewhere on the row, so an event
//   draws only its detail, and an event with no detail draws nothing.
// only → optional filter on which entries to draw.
export function ChangeDiffs({ changes, inline = false, muted = T.slate500, eventsAsDetail = false, only = null }) {
  const list = changeDiffList(changes)
    .filter(c => !only || only(c))
    .filter(c => !(eventsAsDetail && c.event && !c.after));
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

// One click's edits or removals, from production_changes_for_range.
export function ChangeEntry({ r, withDay = false, showWho = true }) {
  const removed = r.what === "removed";
  const item = String(r.item || "record").toLowerCase();
  return (
    <span>
      <ChangeStamp ts={r.changed_at} withDay={withDay} />
      {" · "}
      {showWho ? <span style={{ color: T.slate800 }}>{r.who} </span> : null}
      <span style={{ fontWeight: 700, color: removed ? T.red : T.slate800 }}>{removed ? "removed" : "edited"}</span>
      {` ${/^[aeiou]/.test(item) ? "an" : "a"} ${item}`}
      {r.subject ? <> — <Customer r={r} /></> : null}
      <ChangeDiffs changes={r.changes} inline eventsAsDetail={removed} />
      {Number(r.row_count) > 1 ? <span style={{ color: T.slate500 }}>{` [${r.row_count} records]`}</span> : null}
    </span>
  );
}

// One spot-check note.
export function SpotEntry({ r, withDay = false, showWho = true }) {
  const item = String(r.item || "record").toLowerCase();
  return (
    <span>
      <ChangeStamp ts={r.changed_at} withDay={withDay} />
      {" · "}
      {showWho ? <span style={{ color: T.slate800 }}>{r.who} </span> : null}
      {`noted ${/^[aeiou]/.test(item) ? "an" : "a"} ${item}`}
      {r.subject ? <> — <Customer r={r} /></> : null}
      {": "}
      <span style={{ fontStyle: "italic", color: T.slate800 }}>{r.spot_note}</span>
    </span>
  );
}

function money(v) {
  if (v == null || v === "") return "no issued premium yet";
  const n = Number(v);
  return Number.isFinite(n) ? `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}` : String(v);
}
function day(iso) {
  if (!iso) return "blank";
  const d = new Date(`${String(iso).slice(0, 10)}T12:00:00`);
  return Number.isFinite(d.getTime()) ? d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : String(iso);
}
function Difference({ p }) {
  if (p.difference == null) return null;
  const d = Number(p.difference);
  if (!Number.isFinite(d)) return null;
  if (d === 0) return <span style={{ color: T.slate500 }}> · same as submitted</span>;
  return (
    <span style={{ color: d > 0 ? T.green : T.red, fontWeight: 600 }}>
      {` · ${money(Math.abs(d))} ${d > 0 ? "more" : "less"} than submitted`}
    </span>
  );
}

// One policy issued, marked not issued, or its issue corrected.
export function IssueEntry({ r, withDay = false, showWho = true }) {
  const p = r.policy || {};
  const what = [p.line_of_business ? p.line_of_business[0].toUpperCase() + p.line_of_business.slice(1) : "", p.product || ""]
    .filter(Boolean).join(" ");
  let body;
  if (r.what === "unissued") {
    body = (
      <>
        <span style={{ fontWeight: 700, color: T.red }}>Marked not issued</span>
        <span style={{ color: T.slate500 }}>{` · was issued ${day(p.was_issued_date)} at ${money(p.was_issued_premium)}`}</span>
      </>
    );
  } else if (r.what === "corrected") {
    const parts = [];
    if (String(p.was_issued_date || "") !== String(p.issued_date || "")) parts.push(`issued date ${day(p.was_issued_date)} → ${day(p.issued_date)}`);
    if (Number(p.was_issued_premium ?? NaN) !== Number(p.issued_premium ?? NaN)) {
      parts.push(`issued premium ${p.was_issued_premium == null ? "blank" : money(p.was_issued_premium)} → ${p.issued_premium == null ? "blank" : money(p.issued_premium)}`);
    }
    body = (
      <>
        <span style={{ fontWeight: 700, color: T.amber }}>Issue corrected</span>
        <span>{parts.length ? ` · ${parts.join("; ")}` : ""}</span>
        <Difference p={p} />
      </>
    );
  } else {
    body = (
      <>
        <span style={{ fontWeight: 700, color: T.green }}>Issued {day(p.issued_date)}</span>
        <span>{` · ${money(p.issued_premium)}`}</span>
        <Difference p={p} />
      </>
    );
  }
  return (
    <span>
      <ChangeStamp ts={r.changed_at} withDay={withDay} />
      {" · "}
      {r.subject ? <Customer r={r} /> : <span style={{ fontWeight: 600 }}>Customer</span>}
      {what ? <span style={{ color: T.slate600 }}>{` — ${what}`}</span> : null}
      {" · "}
      {body}
      {showWho ? <span style={{ color: T.slate500 }}>{` · by ${r.who}`}</span> : null}
    </span>
  );
}

// The two-way switch between edits and issued policies.
export function ChangeKindToggle({ value, onChange, counts = {} }) {
  const opts = [{ key: "change", label: "Changes" }, { key: "issue", label: "Issued policies" }, { key: "spot_check", label: "Spot-check notes" }];
  return (
    <div role="group" style={{ display: "inline-flex", flexWrap: "wrap", border: `1px solid ${T.slate300}`, borderRadius: 8, overflow: "hidden" }}>
      {opts.map(o => {
        const on = value === o.key;
        return (
          <button key={o.key} type="button" onClick={() => onChange(o.key)} aria-pressed={on}
            style={{ border: "none", padding: "6px 12px", fontSize: 13, fontWeight: 600, cursor: "pointer",
                     background: on ? T.blue : T.white, color: on ? T.white : T.slate700 }}>
            {o.label}{counts[o.key] != null ? ` (${counts[o.key]})` : ""}
          </button>
        );
      })}
    </div>
  );
}

// Entries grouped by the teammate whose record it is (owner_name from the
// database), each line saying who made the change. The CPR and the Changes tab
// both draw a week this way. exclude = team ids that get no group (the CPR
// leaves the owner out). Order (Peter 2026-09-21): the viewer's own group
// first, then fewest entries to most.
export function groupChangesByOwner(rows, exclude = null, meId = null) {
  const groups = [];
  const byKey = new Map();
  (rows || []).filter(r => !(exclude && exclude.has(r.owner_id))).forEach(r => {
    const key = r.owner_id || "none";
    if (!byKey.has(key)) {
      const g = { key, name: r.owner_id ? (r.owner_name || "Teammate") : "Other", isTeam: !!r.owner_id, rows: [] };
      byKey.set(key, g);
      groups.push(g);
    }
    byKey.get(key).rows.push(r);
  });
  groups.sort((x, y) => {
    const mx = meId && x.key === meId ? 0 : 1;
    const my = meId && y.key === meId ? 0 : 1;
    if (mx !== my) return mx - my;
    if (x.isTeam !== y.isTeam) return x.isTeam ? -1 : 1;
    if (x.rows.length !== y.rows.length) return x.rows.length - y.rows.length;
    return x.name.localeCompare(y.name);
  });
  groups.forEach(g => g.rows.sort((x, y) => String(x.changed_at).localeCompare(String(y.changed_at))));
  return groups;
}

export function ChangeGroups({ groups, kind = "change", maxHeight = 380 }) {
  const Entry = kind === "issue" ? IssueEntry : kind === "spot_check" ? SpotEntry : ChangeEntry;
  const noun = kind === "issue" ? ["policy", "policies"] : kind === "spot_check" ? ["note", "notes"] : ["change", "changes"];
  return (
    <div style={maxHeight ? { maxHeight, overflowY: "auto", WebkitOverflowScrolling: "touch" } : undefined}>
      {groups.map(g => (
        <div key={g.key} style={{ marginBottom: 14 }}>
          <div style={{ display: "flex", flexWrap: "wrap", alignItems: "baseline", gap: 8, marginBottom: 5 }}>
            <span style={{ fontSize: 13, fontWeight: 700, color: T.slate900 }}>{g.name}</span>
            <span style={{ fontSize: 11, color: T.slate500 }}>{g.rows.length} {g.rows.length === 1 ? noun[0] : noun[1]}</span>
          </div>
          {g.rows.map((r, i) => (
            <div key={`${r.kind}-${r.txid}-${i}`} style={{
              fontSize: 12, color: T.slate700, lineHeight: 1.5, paddingLeft: 10, marginBottom: 3,
              borderLeft: `2px solid ${T.slate200}`, boxSizing: "border-box",
            }}>
              <Entry r={r} withDay />
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}
