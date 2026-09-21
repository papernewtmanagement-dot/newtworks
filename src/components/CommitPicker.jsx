import { useState, useId } from "react";
import { supabase } from "../lib/supabase.js";
import { T } from "../lib/theme.js";
import InfoDot from "./InfoDot.jsx";

// ─── Daily commit picker ──────────────────────────────────────
// The week's commit choices as radio buttons plus "Other" with a text box.
// Saving stores today's commit (Central date) for the signed-in teammate
// through kickoff_commit_save; the database refuses a second save for the same
// day, so once saved it is locked (Peter 2026-09-14). One picker for the whole
// app: the Daily Kickoff page and the personal checklist on the Dashboard's
// Checklist tab both render this (Peter 2026-09-21).
//
// Props:
//   items   — [{ text, note }] from commitOptions() in src/lib/markdown.js
//   week    — the kickoff cycle week, saved with the commit
//   onSaved — called with the saved row
//   style   — optional wrapper style

const COMMIT_BTN_PRIMARY = {
  padding: "6px 12px", borderRadius: 7, border: `1px solid ${T.blue}`, background: T.blue,
  color: T.white, font: "inherit", fontSize: 13, fontWeight: 700, cursor: "pointer",
};

// One commit option: the short line, an info button when there is more to it,
// and the explanation underneath once the button is clicked. The option itself
// stays a short line so it reads cleanly on the Telegram messages (Peter
// 2026-09-19); the explanation sits behind the button (Peter 2026-09-21).
// control is the radio button, or nothing for a read-only list.
export function CommitLine({ text, note, control }) {
  const [open, setOpen] = useState(false);
  return (
    <div style={{ margin: "4px 0" }}>
      <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
        {control ? (
          <label style={{ display: "flex", alignItems: "flex-start", gap: 8, cursor: "pointer", flex: "0 1 auto", minWidth: 0 }}>
            {control}
            <span>{text}</span>
          </label>
        ) : <span style={{ minWidth: 0 }}>• {text}</span>}
        {note ? <span style={{ marginTop: 2 }}><InfoDot open={open} onClick={() => setOpen((o) => !o)} /></span> : null}
      </div>
      {note && open ? (
        <div style={{ margin: "4px 0 6px 24px", padding: "8px 10px", background: T.slate50, borderRadius: 8, fontSize: 12.5, color: T.slate700, lineHeight: 1.5 }}>{note}</div>
      ) : null}
    </div>
  );
}

export default function CommitPicker({ items, week, onSaved, style }) {
  const [choice, setChoice] = useState(null);  // index into items, or "other"
  const [other, setOther] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const group = useId();
  const list = Array.isArray(items) ? items : [];

  const save = async () => {
    const text = choice === "other" ? other.trim() : (choice != null ? (list[choice] && list[choice].text) || "" : "");
    if (!text) { setError("Pick a commit or write one."); return; }
    setBusy(true); setError(null);
    const { data, error: e } = await supabase.rpc("kickoff_commit_save", {
      p_text: text,
      p_source: choice === "other" ? "other" : "example",
      p_week: Number.isFinite(Number(week)) && Number(week) > 0 ? Number(week) : null,
    });
    setBusy(false);
    if (e) { setError(e.message); return; }
    if (typeof onSaved === "function") onSaved(data);
  };

  return (
    <div style={style}>
      {list.map((t, i) => (
        <CommitLine key={i} text={t.text} note={t.note}
          control={<input type="radio" name={group} checked={choice === i} onChange={() => setChoice(i)} style={{ marginTop: 5, flexShrink: 0 }} />} />
      ))}
      <label style={{ display: "flex", alignItems: "flex-start", gap: 8, margin: "4px 0", cursor: "pointer" }}>
        <input type="radio" name={group} checked={choice === "other"} onChange={() => setChoice("other")} style={{ marginTop: 5, flexShrink: 0 }} />
        <span style={{ flex: "1 1 200px", minWidth: 0 }}>
          Other
          {choice === "other" && (
            <input
              type="text"
              value={other}
              onChange={(e) => setOther(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); save(); } }}
              placeholder="your own commit, with a number"
              maxLength={400}
              autoFocus
              style={{ display: "block", width: "100%", boxSizing: "border-box", marginTop: 6, padding: "6px 10px", font: "inherit", fontSize: 13, border: `1px solid ${T.slate300}`, borderRadius: 6, background: T.white }}
            />
          )}
        </span>
      </label>
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
        <button type="button" style={{ ...COMMIT_BTN_PRIMARY, opacity: busy || choice == null ? 0.6 : 1 }} disabled={busy || choice == null} onClick={save}>{busy ? "Saving…" : "Save commit"}</button>
      </div>
      {error ? <div style={{ color: T.red, fontSize: 12, fontWeight: 600, marginTop: 6 }}>{error}</div> : null}
    </div>
  );
}
