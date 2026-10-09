import { T } from "../lib/theme.js";

// =========================================================================
// Games.jsx — the one Games page in the sidebar. Lists every game; a tap opens it.
// The games themselves live in their own modules; NewtworksApp routes to them.
// =========================================================================

export const GAMES = [
  { id: "spellingquest", label: "Spelling Quest", text: "Spell words to beat monsters, or to put out the fire." },
  { id: "mathblast",     label: "Math Blast",     text: "Blast asteroids with math to rescue Sprocket the robot pup." },
  { id: "dancer",        label: "Dancer",         text: "An air dancer game played to music." },
  { id: "roleplaying",   label: "Roleplaying",    text: "Character sheets, creatures and the shared world map." },
  { id: "gridstrike",    label: "Gridstrike",     text: "The army-men skirmish game." },
];

export default function Games({ onNavigate }) {
  return (
    <div style={{ padding: 20, maxWidth: 760, margin: "0 auto" }}>
      <div style={{ fontSize: 22, fontWeight: 700, color: T.slate900, marginBottom: 14 }}>Games</div>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))", gap: 12 }}>
        {GAMES.map(g => (
          <button key={g.id} type="button" onClick={() => onNavigate(g.id)}
            style={{ textAlign: "left", cursor: "pointer", fontFamily: "inherit", background: T.white, border: `1px solid ${T.slate200}`, borderRadius: 14, padding: 16, display: "grid", gap: 6 }}>
            <span style={{ fontSize: 17, fontWeight: 700, color: T.slate900 }}>{g.label}</span>
            <span style={{ fontSize: 13, color: T.slate600, lineHeight: 1.4 }}>{g.text}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
