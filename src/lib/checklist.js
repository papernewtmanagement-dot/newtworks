import { T } from "./theme.js";

// The team checklist runs in groups by type: communications, then sales,
// then service, then end of day (Peter 2026-09-25). The group lives on each
// item as item_type. Every row in a group shares one background and the next
// group switches to the other, so the groups read at a glance.
//
// The Checklist tab and the CPR both band through this one function, so the
// two can never color the list differently.
const SHADES = [
  { bg: T.white,    rule: T.slate100 },
  { bg: T.slate100, rule: T.slate200 },
];

// types: each row's group, in list order. Returns one entry per row:
//   bg     the row's background
//   rule   a divider color that shows up on that background
//   first  the row starts its group
//   last   the row ends its group
export function checklistBands(types) {
  const list = Array.isArray(types) ? types : [];
  let shade = 0;
  return list.map((t, i) => {
    const first = i === 0 || t !== list[i - 1];
    if (i > 0 && first) shade = 1 - shade;
    return { ...SHADES[shade], first, last: i === list.length - 1 || t !== list[i + 1] };
  });
}
