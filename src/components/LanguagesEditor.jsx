import { T } from "../lib/theme.js";

// The ONE place the language list, the levels and the language picker live.
// Used by the offer acceptance page and the Team card. Levels must match the
// database's normalize_languages(). Each level is worded as something you can
// actually do, because people rate themselves far more accurately that way
// than against labels like "intermediate" (Ross 1998). They line up with the
// Interagency Language Roundtable scale (ILR 1, 2, 3, 4-5).

export const LANGUAGE_CHOICES = [
  "English", "Spanish", "Vietnamese", "Chinese (Mandarin)", "Chinese (Cantonese)",
  "Tagalog", "Korean", "Arabic", "Hindi", "Urdu", "French", "German",
  "Portuguese", "Russian", "Japanese", "American Sign Language",
];

export const LANGUAGE_LEVELS = [
  { key: "basic", short: "Basic", label: "Basic: simple words and phrases" },
  { key: "conversational", short: "Conversational", label: "Conversational: everyday conversation" },
  { key: "professional", short: "Professional", label: "Professional: could explain a policy to a customer" },
  { key: "native", short: "Native or fluent", label: "Native or fully fluent" },
];

export const EMPTY_LANG = { language: "", other: "", proficiency: "" };

// Saved shape [{language, proficiency}] -> editor rows.
export function languagesToRows(saved) {
  const list = Array.isArray(saved) ? saved : [];
  return list.map((l) => {
    const name = (l?.language || "").trim();
    if (!name) return { ...EMPTY_LANG };
    const known = LANGUAGE_CHOICES.find((c) => c.toLowerCase() === name.toLowerCase());
    return known
      ? { language: known, other: "", proficiency: l?.proficiency || "" }
      : { language: "Other", other: name, proficiency: l?.proficiency || "" };
  });
}

// Editor rows -> saved shape. Fully blank rows are dropped.
export function rowsToLanguages(rows) {
  return (rows || [])
    .map((r) => ({
      language: ((r.language === "Other" ? r.other : r.language) || "").trim(),
      proficiency: r.proficiency || "",
    }))
    .filter((l) => l.language || l.proficiency);
}

// Short text for display, e.g. "English (Native or fluent), Spanish (Professional)".
export function languagesText(saved) {
  const list = Array.isArray(saved) ? saved : [];
  if (!list.length) return "";
  return list
    .map((l) => {
      const lv = LANGUAGE_LEVELS.find((x) => x.key === l?.proficiency);
      return lv ? `${l.language} (${lv.short})` : l?.language;
    })
    .filter(Boolean)
    .join(", ");
}

export default function LanguagesEditor({ rows, onChange, inputStyle, labelStyle }) {
  const list = Array.isArray(rows) && rows.length ? rows : [{ ...EMPTY_LANG }];
  const set = (i, k, v) => onChange(list.map((r, idx) => (idx === i ? { ...r, [k]: v } : r)));
  const add = () => onChange([...list, { ...EMPTY_LANG }]);
  const remove = (i) => onChange(list.length > 1 ? list.filter((_, idx) => idx !== i) : [{ ...EMPTY_LANG }]);
  const btn = {
    padding: "8px 12px", fontSize: 13, background: "#fff", color: T?.slate600 || "#475569",
    border: `1px solid ${T?.slate200 || "#e2e8f0"}`, borderRadius: 8, cursor: "pointer",
    fontFamily: "inherit", boxSizing: "border-box",
  };

  return (
    <div>
      {list.map((l, i) => (
        <div key={i} style={{ display: "flex", flexWrap: "wrap", gap: 10, marginBottom: 10, alignItems: "flex-end" }}>
          <div style={{ flex: "1 1 160px" }}>
            <label style={labelStyle}>Language</label>
            <select style={inputStyle} value={l.language} onChange={(e) => set(i, "language", e.target.value)}>
              <option value="">Pick one</option>
              {LANGUAGE_CHOICES.map((c) => <option key={c} value={c}>{c}</option>)}
              <option value="Other">Other</option>
            </select>
            {l.language === "Other" && (
              <input style={{ ...inputStyle, marginTop: 6 }} value={l.other} placeholder="Which language?"
                     onChange={(e) => set(i, "other", e.target.value)} />
            )}
          </div>
          <div style={{ flex: "2 1 220px" }}>
            <label style={labelStyle}>How well</label>
            <select style={inputStyle} value={l.proficiency} onChange={(e) => set(i, "proficiency", e.target.value)}>
              <option value="">Pick one</option>
              {LANGUAGE_LEVELS.map((lv) => <option key={lv.key} value={lv.key}>{lv.label}</option>)}
            </select>
          </div>
          {list.length > 1 && (
            <button type="button" onClick={() => remove(i)} title="Remove this language" style={btn}>Remove</button>
          )}
        </div>
      ))}
      <button type="button" onClick={add}
              style={{ ...btn, fontWeight: 600, color: T?.blue || "#737A59" }}>
        + Add another language
      </button>
    </div>
  );
}
