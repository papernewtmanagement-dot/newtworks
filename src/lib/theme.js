// ============================================================
// paper newt brand — single source of truth for color tokens
// ------------------------------------------------------------
// Version 1.0 — June 2026
//
// Every module under src/modules/ and NewtworksApp.jsx imports from
// this file. Do not declare local color-token objects in modules.
// If a brand value needs to change, change it HERE and only here.
//
// Palette grounded in the v1.0 brand guidelines PDF:
//   /02_logos/, /03_palette/ in the paper newt brand package.
//
// Two exports:
//   - T       — used by modules (matches their legacy local name)
//   - TOKENS  — alias for NewtworksApp.jsx (matches its legacy local name)
//
// Key NAMES preserved across the legacy palette + 4 supporting
// accent families (gold, pink, purple, teal) so every existing
// call site keeps working. Only the hex VALUES are brand-aware.
// ============================================================

export const T = {
  // ─── accent (sage) ────────────────────────────────────────
  // Primary mark color. Cream/stone values live in the slate ramp below.
  blue:     "#737A59",   // Sage Primary — accent / mark color
  blueLt:   "#ECEFE4",   // Sage Mist — active-state background

  // ─── neutrals (cream → stone → olive → charcoal ramp) ────
  slate50:  "#FAF7F0",   // Cream
  slate100: "#F3EFE5",   // Cream-Stone
  slate200: "#E8E2D1",   // Warm Stone
  slate300: "#D4CDB8",   // Stone-Deep
  slate400: "#7A7C6E",   // Olive-Mid — secondary text (bumped from #A8A99A for AA contrast on cream)
  slate500: "#6E7163",   // Olive-Light — body sub-text
  slate600: "#5C5E50",   // Olive-Mid
  slate700: "#4D503F",   // Olive Charcoal — body text
  slate800: "#3B3E32",   // Deep Olive
  slate900: "#2D2F26",   // Charcoal — headlines, deepest text
  white:    "#FFFFFF",   // Paper White — cards, sheets


  // ─── chrome surfaces (sage shell wrapping cream/white workspace) ──
  // Used for header bar + sidebar nav. Anchors the brand identity
  // without making content surfaces hard to read against.
  chromeBg:      "#737A59",  // Sage Primary — primary chrome surface
  chromeBgDeep:  "#5C6447",  // Sage Deeper — active nav fill, hover
  chromeText:    "#F3EFE5",  // Cream-Stone — primary text on chrome
  chromeTextDim: "#C9CCB8",  // Muted cream — secondary text/icons on chrome
  chromeBorder:  "#5C6447",  // Sage Deeper — borders within chrome

  // ─── semantic (unchanged — universal meaning) ────────────
  green:    "#10B981",   // success
  greenLt:  "#D1FAE5",
  amber:    "#F59E0B",   // warning
  amberLt:  "#FEF3C7",
  red:      "#EF4444",   // danger / error
  redLt:    "#FEE2E2",

  // ─── supporting accents (brand-coherent muted set) ───────
  // Used for category badges, chart series, principles tags.
  // All desaturated, warm-leaning — they pair with sage/cream.
  gold:     "#A88B5F",   // aged brass — accolade / achievement
  goldLt:   "#F2E8D5",
  pink:     "#A87A75",   // muted rose
  pinkLt:   "#F2DDDA",
  purple:   "#6E5B7A",   // plum
  purpleLt: "#E3D7E3",
  teal:     "#5E7A77",   // sage-teal
  tealLt:   "#D5E2DF",
};

// ─── Sales Points band palette (Peter 2026-08-28) ──────────────────
// Red, yellow, green, blue, charcoal — ascending. Tuned warm to sit in
// the cream/sage shell rather than shouting over it. Note T.blue is the
// SAGE primary (#737A59), not a blue, so Great carries its own dusty
// blue. Elite keeps the traditional black-tier look: charcoal ink on a
// cool platinum band, and a solid charcoal badge with white lettering —
// it is the only achromatic and the only cool-toned band, so it cannot
// be confused with the four below it.
//   ink      chart band label and boundary line
//   fill     chart band wash
//   badgeBg  small badge on the CPR and Team cards
//   badgeFg  badge lettering
export const BAND = {
  Danger:  { ink: "#D14343", fill: "#FBE0DE", badgeBg: "#FBE0DE", badgeFg: "#8E2A22" },
  Caution: { ink: "#D4A017", fill: "#FAEFC8", badgeBg: "#FAEFC8", badgeFg: "#7A5B08" },
  Good:    { ink: "#2E8B57", fill: "#D8EFDF", badgeBg: "#D8EFDF", badgeFg: "#1B5E36" },
  Great:   { ink: "#255C99", fill: "#D9E5F2", badgeBg: "#D9E5F2", badgeFg: "#1D4E89" },
  Elite:   { ink: "#2D2F26", fill: "#C9CDD6", badgeBg: "#2D2F26", badgeFg: "#FFFFFF" },
};

// Alias for NewtworksApp.jsx which historically imports the object as TOKENS.
// Same object reference — change T, both update.
export const TOKENS = T;
