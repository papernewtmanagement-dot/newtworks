import { useState } from "react";
import { T } from "../lib/theme.js";
import { useViewport } from "../lib/hooks.js";
import { PopupShell, Button, inputBase, splitIndent, wrapLongText } from "../lib/onboardingUi.jsx";

// =========================================================================
// ReplyPopup.jsx
// Opens when a new hire ticks a line that asks for a reply ("What's one
// takeaway?"). Saving ticks the line and keeps what they typed; the card
// then shows their reply in place of the question. asksForReply() in
// onboardingUi.jsx decides which lines open this.
// =========================================================================
export default function ReplyPopup({ label, onSave, onClose }) {
  const vp = useViewport();
  const [text, setText] = useState("");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState("");
  const question = splitIndent(label).text;

  const save = async () => {
    const v = text.trim();
    if (!v) { setErr("Type your answer first."); return; }
    setSaving(true);
    setErr("");
    const e = await onSave(v);
    setSaving(false);
    if (e) setErr(e);
  };

  return (
    <PopupShell onClose={onClose} maxWidth={480}>
      <div style={{ padding: vp.isPhone ? "18px 16px" : "22px 24px", minWidth: 0, ...wrapLongText }}>
        <div style={{ fontSize: 17, fontWeight: 700, color: T.slate900, paddingRight: 30 }}>{question}</div>
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          rows={4}
          autoFocus
          style={{ ...inputBase, marginTop: 12, resize: "vertical", fontFamily: "inherit", lineHeight: 1.5 }}
        />
        {err && <div style={{ marginTop: 8, fontSize: 12, color: T.red }}>{err}</div>}
        <div style={{ marginTop: 12, display: "flex", gap: 8, flexWrap: "wrap" }}>
          <Button onClick={save} disabled={saving}>{saving ? "Saving…" : "Save"}</Button>
          <Button variant="secondary" onClick={onClose} disabled={saving}>Cancel</Button>
        </div>
      </div>
    </PopupShell>
  );
}
