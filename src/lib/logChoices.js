// The Log's fixed choices, named once. The Log form, History, the customer
// popup and the Live tab all read these, so a choice is never written two ways
// and a label can't drift between screens (Peter 2026-10-04).

// Peter's three relationship values.
export const RELATIONSHIPS = [
  { key: "new",      label: "New" },
  { key: "existing", label: "Existing" },
  { key: "winback",  label: "Winback" },
];
// Anything that is not New or Winback reads Existing, the way History always has.
export const relationshipLabel = (key) => (RELATIONSHIPS.find((r) => r.key === key) || RELATIONSHIPS[1]).label;

// Peter 2026-09-19: an Online Review has to say where it landed.
export const REVIEW_SITES = [
  { key: "google",   label: "Google" },
  { key: "facebook", label: "Facebook" },
  { key: "yelp",     label: "Yelp" },
];
export const reviewSiteLabel = (key) => (REVIEW_SITES.find((s) => s.key === key) || {}).label || key || "";
