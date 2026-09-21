import { useState, useId } from "react";
import { supabase } from "../lib/supabase.js";
import { T } from "../lib/theme.js";

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

// The explanation behind a commit option. The option itself is a short line so
// it reads cleanly on the Telegram messages; anything that needs more words
// sits in here (Peter 2026-09-19).
export function CommitNote({ note }) {
  return (
    <details style={{ margin: "2px 0 0 24px" }}>
      <summary style={{ cursor: "pointer", fontSize: 12, color: T.slate500, listStyle: "none" }}>What this means</summary>
      <div style={{ fontSize: 13, color: T.slate700, marginTop: 4 }}>{note}</div>
    </details>
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
        <div key={i} style={{ margin: "4px 0" }}>
          <label style={{ display: "flex", alignItems: "flex-start", gap: 8, cursor: "pointer" }}>
            <input type="radio" name={group} checked={choice === i} onChange={() => setChoice(i)} style={{ marginTop: 5, flexShrink: 0 }} />
            <span>{t.text}</span>
          </label>
          {t.note ? <CommitNote note={t.note} /> : null}
        </div>
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
