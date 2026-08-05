import { T } from "../lib/theme.js";

// Renders HireGauge GMA numerical-reasoning items (the second of 4 planned
// GMA subtests -- pattern-matching, numerical [this], deductive, verbal).
// Item type: a 5-number sequence with the 6th value missing; candidate picks
// the correct next number from 6 lettered options.
//
// Item data shape (hiregauge_instrument_items.choices for
// cognitive_domain='gma_numerical'):
//   {
//     sequence: [n1, n2, n3, n4, n5],
//     options: { A: number, ..., F: number }
//   }
// Distinct from the pattern-matching shape ({ grid, options }) -- this is
// why isGmaNumericalItem() checks for `sequence`, not `grid`. Never
// confuse the two checks; an item can only match one.

const GMA_NUMERICAL_INSTRUCTION =
  "Look at the number sequence below. Figure out the rule, then choose the number that comes next.";

export function isGmaNumericalItem(item) {
  return !!(
    item &&
    item.choices &&
    !Array.isArray(item.choices) &&
    Array.isArray(item.choices.sequence)
  );
}

function SequenceRow({ sequence, vp }) {
  const cellSize = vp.isPhone ? 44 : 56;
  const cells = [...sequence, null]; // null = the "?" slot being solved for
  return (
    <div
      style={{
        display: "flex",
        flexWrap: "wrap",
        gap: vp.isPhone ? 8 : 10,
        justifyContent: "center",
        margin: "0 auto 24px",
      }}
    >
      {cells.map((n, i) => (
        <div
          key={i}
          style={{
            minWidth: cellSize,
            height: cellSize,
            padding: "0 8px",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            border: `1px solid ${T.slate200}`,
            borderRadius: 8,
            background: n === null ? T.slate50 : T.white,
            color: n === null ? T.slate400 : T.slate900,
            fontSize: vp.isPhone ? 16 : 18,
            fontWeight: 700,
            boxSizing: "border-box",
          }}
        >
          {n === null ? "?" : n}
        </div>
      ))}
    </div>
  );
}

function OptionGrid({ options, onAnswer, selected, saving, vp }) {
  const letters = ["A", "B", "C", "D", "E", "F"];
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "repeat(auto-fit, minmax(110px, 1fr))",
        gap: 10,
      }}
    >
      {letters.map((letter) => {
        const value = options?.[letter];
        if (value === undefined || value === null) return null;
        return (
          <button
            key={letter}
            disabled={saving}
            onClick={() => onAnswer({ label: letter })}
            style={{
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              gap: 4,
              padding: "14px 8px",
              background: selected?.label === letter ? T.blueLt : T.white,
              border: `1px solid ${selected?.label === letter ? T.blue : T.slate200}`,
              borderRadius: 8,
              cursor: saving ? "wait" : "pointer",
              boxSizing: "border-box",
            }}
          >
            <span style={{ fontSize: vp.isPhone ? 17 : 19, fontWeight: 700, color: T.slate900 }}>
              {value}
            </span>
            <span style={{ fontSize: 12, fontWeight: 700, color: T.blue }}>{letter}</span>
          </button>
        );
      })}
    </div>
  );
}

export default function GmaNumericalItem({ item, onAnswer, selected, saving, vp }) {
  const sequence = item?.choices?.sequence;
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
        {GMA_NUMERICAL_INSTRUCTION}
      </div>
      <SequenceRow sequence={sequence} vp={vp} />
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
        Choose the missing number
      </div>
      <OptionGrid options={options} onAnswer={onAnswer} selected={selected} saving={saving} vp={vp} />
    </div>
  );
}
