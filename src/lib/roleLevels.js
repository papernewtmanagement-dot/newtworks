// Single source of truth for role-level ordering and the manager tier.
//
// Handbook "Your Path Through the Agency": a Unit Manager runs 3-5 team
// members, a Section Manager runs 3-5 units, an Office Manager runs 3-5
// sections. So the ladder runs Account Associate -> Account Manager ->
// Unit Manager -> Section Manager -> Office Manager -> Owner.
//
// Mirrors public.role_level_rank() and public.manager_tier_levels() in the
// database. Change both together.

// Highest first. Use this for every role-level dropdown so the list always
// reads top-down in the same order.
export const ROLE_LEVELS = [
  "Owner",
  "Office Manager",
  "Section Manager",
  "Unit Manager",
  "Account Manager",
  "Account Associate",
];

// Levels that carry a personal production target, the Win the Week personal
// minimum, and the four-day-week perk. Owner is deliberately out.
export const MANAGER_TIER_LEVELS = [
  "Account Manager",
  "Unit Manager",
  "Section Manager",
  "Office Manager",
];

export const isManagerTier = (roleLevel) =>
  MANAGER_TIER_LEVELS.includes(roleLevel || "");

export const roleLevelRank = (roleLevel) => {
  const i = ROLE_LEVELS.indexOf(roleLevel || "");
  return i === -1 ? 99 : i;
};
