import { T } from "../lib/theme.js";

// Renders HireGauge GMA (General Mental Ability) pattern-matching items —
// a 3x3 grid of shapes with one cell missing, plus 6 lettered options (A-F)
// the candidate picks from to complete the pattern.
//
// Item data shape (hiregauge_instrument_items.choices for
// section='newtworks_v2_cognitive_gma'):
//   {
//     grid: [ {shape, fill, size, count, rotation}, ... 8 cells, null ],
//     options: { A: {shape,fill,size,count,rotation}, ..., F: {...} }
//   }
// The 9th grid cell (index 8) is always null — that's the piece the
// candidate is solving for. answer_key on the item row holds the correct
// letter; this component does not need it, it just reports the letter the
// candidate picked via onAnswer({ label: "F" }) — same save-path shape the
// existing text multi-choice branch in CandidateAssessment.jsx already uses.

const INK = T.slate900;
const SIZE_R = { s: 13, m: 19, l: 26 };

// Fixed candidate-facing instruction. Do NOT source this from item_text —
// item_text for this item type holds the generator's internal rule
// description (e.g. "Shape steps circle->square->triangle left to right"),
// which names the solving rule outright. That's QA/authoring metadata, not
// something a candidate should ever see.
const GMA_INSTRUCTION =
  'Look at the pattern in the grid. One piece is missing, shown as "?". Choose the option below that completes the pattern.';

export function isGmaPatternItem(item) {
  return !!(
    item &&
    item.choices &&
    !Array.isArray(item.choices) &&
    item.choices.grid
  );
}

function polygonPoints(cx, cy, r, anglesDeg) {
  return anglesDeg
    .map((deg) => {
      const rad = (deg * Math.PI) / 180;
      return `${(cx + r * Math.cos(rad)).toFixed(2)},${(cy + r * Math.sin(rad)).toFixed(2)}`;
    })
    .join(" ");
}

function ShapeGlyph({ shape, cx, cy, r, rotation, fill, patternId }) {
  const rot = Number.isFinite(rotation) ? rotation : 0;
  const transform = `rotate(${rot} ${cx} ${cy})`;
  const fillProps =
    fill === "outline"
      ? { fill: "none", stroke: INK, strokeWidth: 3 }
      : fill === "striped"
      ? { fill: `url(#${patternId})`, stroke: INK, strokeWidth: 1.5 }
      : { fill: INK, stroke: "none" };

  if (shape === "circle") {
    // Rotation is visually meaningless on a circle (infinite rotational
    // symmetry) — per the GMA design op-rule, the generator never puts a
    // rotation rule on circle/square for this reason. Transform is harmless
    // no-op here, kept only for prop-shape consistency.
    return <circle cx={cx} cy={cy} r={r} transform={transform} {...fillProps} />;
  }
  if (shape === "square") {
    return (
      <rect
        x={cx - r}
        y={cy - r}
        width={r * 2}
        height={r * 2}
        transform={transform}
        {...fillProps}
      />
    );
  }
  if (shape === "triangle") {
    return (
      <polygon
        points={polygonPoints(cx, cy, r, [270, 30, 150])}
        transform={transform}
        {...fillProps}
      />
    );
  }
  if (shape === "rightTriangle") {
    const pts = `${cx - r},${cy + r} ${cx + r},${cy + r} ${cx - r},${cy - r}`;
    return <polygon points={pts} transform={transform} {...fillProps} />;
  }
  if (shape === "arrow") {
    const pts = [
      `${cx},${cy - r}`,
      `${cx + r * 0.75},${cy + r * 0.35}`,
      `${cx + r * 0.3},${cy + r * 0.35}`,
      `${cx + r * 0.3},${cy + r}`,
      `${cx - r * 0.3},${cy + r}`,
      `${cx - r * 0.3},${cy + r * 0.35}`,
      `${cx - r * 0.75},${cy + r * 0.35}`,
    ].join(" ");
    return <polygon points={pts} transform={transform} {...fillProps} />;
  }
  if (shape === "hexagon") {
    return (
      <polygon
        points={polygonPoints(cx, cy, r, [270, 330, 30, 90, 150, 210])}
        transform={transform}
        {...fillProps}
      />
    );
  }
  // Unknown shape name — fail loudly (visible red "?") instead of silently
  // rendering a blank cell, so a bad item slips through review, not to a
  // candidate unnoticed.
  return (
    <text x={cx} y={cy + 5} textAnchor="middle" fontSize={16} fill={T.red}>
      ?
    </text>
  );
}

function CellFigure({ spec, cellId }) {
  if (!spec) {
    return (
      <svg viewBox="0 0 100 100" width="100%" height="100%" style={{ display: "block" }}>
        <text
          x="50"
          y="63"
          textAnchor="middle"
          fontSize="42"
          fontWeight="700"
          fill={T.slate400}
        >
          ?
        </text>
      </svg>
    );
  }
  const patternId = `gma-stripe-${cellId}`;
  const r = SIZE_R[spec.size] || SIZE_R.m;
  const count = Math.max(1, Math.min(4, Number.isFinite(spec.count) ? spec.count : 1));
  const perR = count > 1 ? r * 0.62 : r;
  const spacing = perR * 2.15;
  const xs = Array.from({ length: count }, (_, i) => 50 + (i - (count - 1) / 2) * spacing);

  return (
    <svg viewBox="0 0 100 100" width="100%" height="100%" style={{ display: "block" }}>
      {spec.fill === "striped" ? (
        <defs>
          <pattern
            id={patternId}
            patternUnits="userSpaceOnUse"
            width="6"
            height="6"
            patternTransform="rotate(45)"
          >
            <rect width="6" height="6" fill={T.white} />
            <line x1="0" y1="0" x2="0" y2="6" stroke={INK} strokeWidth="2.5" />
          </pattern>
        </defs>
      ) : null}
      {xs.map((x, i) => (
        <ShapeGlyph
          key={i}
          shape={spec.shape}
          cx={x}
          cy={50}
          r={perR}
          rotation={spec.rotation}
          fill={spec.fill}
          patternId={patternId}
        />
      ))}
    </svg>
  );
}

function PatternGrid({ grid, vp }) {
  const cellPx = vp.isPhone ? 66 : 84;
  const cells = Array.isArray(grid) ? grid.slice(0, 9) : [];
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: `repeat(3, ${cellPx}px)`,
        gridTemplateRows: `repeat(3, ${cellPx}px)`,
        gap: vp.isPhone ? 6 : 8,
        justifyContent: "center",
        margin: "0 auto 24px",
      }}
    >
      {cells.map((spec, i) => (
        <div
          key={i}
          style={{
            width: cellPx,
            height: cellPx,
            border: `1px solid ${T.slate200}`,
            borderRadius: 6,
            background: T.white,
            boxSizing: "border-box",
          }}
        >
          <CellFigure spec={spec} cellId={`grid-${i}`} />
        </div>
      ))}
    </div>
  );
}

function OptionGrid({ options, onAnswer, selected, saving, vp }) {
  const letters = ["A", "B", "C", "D", "E", "F"];
  const cellPx = vp.isPhone ? 60 : 72;
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "repeat(auto-fit, minmax(110px, 1fr))",
        gap: 10,
      }}
    >
      {letters.map((letter) => {
        const spec = options?.[letter];
        if (!spec) return null;
        return (
          <button
            key={letter}
            disabled={saving}
            onClick={() => onAnswer({ label: letter })}
            style={{
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              gap: 6,
              padding: "10px 8px",
              background: selected?.label === letter ? T.blueLt : T.white,
              border: `1px solid ${selected?.label === letter ? T.blue : T.slate200}`,
              borderRadius: 8,
              cursor: saving ? "wait" : "pointer",
              boxSizing: "border-box",
            }}
          >
            <div style={{ width: cellPx, height: cellPx }}>
              <CellFigure spec={spec} cellId={`opt-${letter}`} />
            </div>
            <span style={{ fontSize: 13, fontWeight: 700, color: T.blue }}>{letter}</span>
          </button>
        );
      })}
    </div>
  );
}

export default function GmaPatternItem({ item, onAnswer, selected, saving, vp }) {
  const grid = item?.choices?.grid;
  const options = item?.choices?.options;
  return (
    <div>
      <div
        style={{
          fontSize: vp.isPhone ? 15 : 16,
          lineHeight: 1.5,
          color: T.slate700,
          marginBottom: 20,
          fontWeight: 500,
        }}
      >
        {GMA_INSTRUCTION}
      </div>
      <PatternGrid grid={grid} vp={vp} />
      <div
        style={{
          fontSize: 12,
          fontWeight: 700,
          letterSpacing: 0.5,
          textTransform: "uppercase",
          color: T.slate500,
          marginBottom: 10,
          textAlign: "center",
        }}
      >
        Choose the missing piece
      </div>
      <OptionGrid options={options} onAnswer={onAnswer} selected={selected} saving={saving} vp={vp} />
    </div>
  );
}
