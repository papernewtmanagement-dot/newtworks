// Password managers (LastPass, 1Password, Bitwarden, Dashlane, Proton Pass)
// read customer boxes as login or address fields and put their icon in them.
// Spread this onto every one: the data attributes are each vendor's own
// opt-out. Two things the attributes alone do not cover, both handled here:
// LastPass ignores autoComplete "off", so each box gets a nonsense token
// instead; and when a box has no name or id LastPass falls back to guessing
// from the nearby label, so each box gets a meaningless name and id. Pass a
// short opaque key that says nothing about the field, unique on the page.
// Suppressing one box only moves the offer to the next one, so they all carry it.
// Moved here from ActivityLog.jsx 2026-09-25 so the Dewey worksheet's customer
// boxes use the same one.
export const noPwManager = (key) => ({
  name: `nw${key}`, id: `nw${key}`, autoComplete: `nw${key}-x`,
  "data-lpignore": "true", "data-1p-ignore": true, "data-bwignore": true,
  "data-protonpass-ignore": true, "data-form-type": "other",
});
