# Earning Potential chart checks

Server-renders `EarningsCurveChart` at both breakpoints and asserts the
things that have actually broken in production, instead of eyeballing the
page.

    node tests/chart/run.mjs

## Why each check exists

- **Undefined variables.** A syntax check passes on code that references a
  variable that no longer exists. A tidy-up removed `legendAt` and the tab
  crashed on load; a later one removed `axisFor` and was caught here first.
- **Repeated money labels.** The base line is drawn sloped, so two label
  positions on the same run both rounded to `$35K` and both drew. Checked on
  the uneven rung spacing that produced it — the 50-point spacing in use
  today happens not to collide, so the current data alone would not catch a
  regression. Grouped by fill colour so the three pay lines are compared
  separately, and the left gutter is skipped because the y-axis scale shares
  the base line's colour.
- **Kinks in the total line.** The team bonus is solved per grid row against
  a commission rate curve that steps, so the drawn total came out ragged.
  Counts sign flips in the second difference of the drawn path. The test
  bonus is deliberately lumpy for this reason.
- **Ladder alignment.** Every raise rung must sit exactly on its own weekly
  pace on the axis. Asserts under 0.6px of drift.
- **Band header text.** Nicknames, applicant shares and traits come from
  `pay_scale` now; this proves they reach the page.
- **Axis overrun.** Nothing may be drawn past the end of the band pattern.

## How it works

`stubs/` replaces only the three browser-only imports (Supabase, routing,
viewport). The theme and the money formatter are the real modules, so colour
and format changes are exercised for real.
