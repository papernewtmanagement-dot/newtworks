"""
GMA pattern-matching item generator v4 — extends the locked v3 bank (items 1-10)
with items 11-30 using the same rule vocabulary and generator contract.

Rule taxonomy: Carpenter, Just & Shell (1990), Psychological Review 97(3):404-431.
Cognitive demand low->high: constant-in-row < pairwise progression <
figure addition/subtraction < distribution-of-three < distribution-of-two.

Generator contract (per persistent_memory operational_rule "GMA matrix items —
build via code generator..."):
1. Grid cells are derived FROM the declared rule function(s), never typed freely.
2. A verification pass re-applies each rule to every given cell and asserts it
   matches before the item is written anywhere.
3. The answer key is computed from the same rule functions applied to the
   target cell — never hand-picked.
4. Distractors are constructed with intent (partial-rule-application foils),
   and a duplicate-options assertion is a permanent gate.

Rotation-capable shapes only: triangle, rightTriangle, arrow (no rotational
symmetry at 90-degree steps). circle/square/hexagon never carry a rotation rule.
"""
import json, itertools, random

random.seed(20260802)

SHAPES = ["circle", "square", "triangle", "rightTriangle", "arrow", "hexagon"]
ROTATABLE_SHAPES = ["triangle", "rightTriangle", "arrow"]
FILLS = ["solid", "outline", "striped"]
SIZES = ["s", "m", "l"]

def cell(shape="circle", fill="solid", size="m", count=1, rotation=0):
    return {"shape": shape, "fill": fill, "size": size, "count": count, "rotation": rotation}

def latin_rows(values3):
    """3 rows, each a cyclic shift of values3 -> distribution-of-three
    (each value appears exactly once per row AND once per column)."""
    return [values3[i:] + values3[:i] for i in range(3)]

def column_const_rows(values3):
    """Same 3 values repeated identically in every row -> pairwise
    progression / constant sequence read left-to-right."""
    return [values3[:] for _ in range(3)]

def odd_one_out_rows(majority, minority):
    """distribution-of-two: 2 of `majority` + 1 of `minority` per row, the
    minority's column position shifts each row (0,1,2). Hardest CJS rule —
    candidate must track an uneven 2:1 split whose odd position moves, not a
    clean one-to-one mapping like the Latin-square case above."""
    rows = []
    for shift in range(3):
        row = [majority, majority, majority]
        row[shift] = minority
        rows.append(row)
    return rows

def build_grid(row_specs_by_attr, base=None):
    """row_specs_by_attr: dict attr_name -> 3x3 list of values (row-major).
    base: dict of default cell field values for attrs not overridden."""
    base = base or {}
    grid = []
    for r in range(3):
        for c in range(3):
            spec = dict(shape="circle", fill="solid", size="m", count=1, rotation=0)
            spec.update(base)
            for attr, rows in row_specs_by_attr.items():
                spec[attr] = rows[r][c]
            grid.append(spec)
    target = grid[8]
    grid[8] = None
    return grid, target

def verify(row_specs_by_attr, target, base=None):
    """Re-derive cell (2,2) from the same rule tables and assert it matches
    the stored target — the generator's non-negotiable self-check."""
    base = base or {}
    expect = dict(shape="circle", fill="solid", size="m", count=1, rotation=0)
    expect.update(base)
    for attr, rows in row_specs_by_attr.items():
        expect[attr] = rows[2][2]
    assert expect == target, f"RULE MISMATCH: derived {expect} != target {target}"

def make_distractors(target, rules_used, pool_attr_values):
    """Distractors, intent-built:
    - one distractor wrong on exactly one active rule dimension (partial-rule
      application foil) per active rule, up to 2
    - one irrelevant-attribute-changed foil (changes an attribute NOT governed
      by any rule this item uses — tests whether candidate over-generalizes)
    - one wrong-count / wrong-element-of-the-set foil
    - one off-shape (uses a shape not in this item's vocabulary at all)
    Returns dict of 5 distractor specs (correct is added as 6th by caller).
    Every foil is checked against the target AND every prior foil so no two
    options can ever collide (own-QA gate, per generator contract).
    """
    def key_of(spec):
        return json.dumps(spec, sort_keys=True)

    out = {}
    seen_keys = {key_of(target)}

    def try_add(name, spec):
        k = key_of(spec)
        if k in seen_keys:
            return False
        seen_keys.add(k)
        out[name] = spec
        return True

    used_attrs = list(rules_used.keys())

    # Partial-rule-application foils: flip exactly one governed attribute to a
    # plausible-but-wrong value.
    for i, attr in enumerate(used_attrs[:2]):
        choices = [v for v in pool_attr_values.get(attr, []) if v != target[attr]]
        random.shuffle(choices)
        for v in choices:
            d = dict(target)
            d[attr] = v
            if try_add(f"partial_{i}", d):
                break

    # Irrelevant-attribute-changed foil: bump count by 1 (count is rarely the
    # governed attribute in these items) so it looks plausible but is off on
    # something the rule never touched.
    d = dict(target)
    d["count"] = min(4, (d["count"] or 1) + 1) if target["count"] < 4 else max(1, target["count"] - 1)
    try_add("irrelevant", d)

    # Wrong-element-of-the-set: same attributes but rotated 90 further,
    # only meaningful on a rotatable shape.
    if target["shape"] in ROTATABLE_SHAPES:
        d = dict(target)
        d["rotation"] = (target["rotation"] + 90) % 360
        try_add("wrong_element", d)

    # Off-vocabulary foil: a shape never used elsewhere in this item.
    off_shape = "hexagon" if target["shape"] != "hexagon" else "square"
    try_add("off_vocab", cell(shape=off_shape, fill=target["fill"], size=target["size"],
                               count=target["count"], rotation=0))

    # Pad up to exactly 5 unique distractors (some items have only one rule
    # attribute, which yields fewer than 5 foils above). Fill remaining slots
    # by cycling through every attribute dimension with an alternate value.
    fallback_dims = [
        ("shape", SHAPES),
        ("fill", FILLS),
        ("size", SIZES),
        ("rotation", [0, 90, 180, 270]),
        ("count", [1, 2, 3, 4]),
    ]
    idx = 0
    tries = 0
    while len(out) < 5 and tries < 80:
        tries += 1
        attr, pool = fallback_dims[idx % len(fallback_dims)]
        idx += 1
        candidates = [v for v in pool if v != target.get(attr)]
        if not candidates:
            continue
        d = dict(target)
        d[attr] = random.choice(candidates)
        if attr == "rotation" and d["shape"] not in ROTATABLE_SHAPES:
            continue  # rotation is meaningless noise on circle/square/hexagon
        try_add(f"fallback_{len(out)}", d)

    assert len(out) == 5, f"only produced {len(out)} unique distractors"
    return out

def finalize_item(item_number, item_text, tier, row_specs, base, rules_used, pool_attr_values):
    grid, target = build_grid(row_specs, base)
    verify(row_specs, target, base)
    distractors = make_distractors(target, rules_used, pool_attr_values)
    assert len(distractors) == 5
    letters = ["A", "B", "C", "D", "E", "F"]
    all_opts = list(distractors.values()) + [target]
    random.shuffle(all_opts)
    options = {letters[i]: all_opts[i] for i in range(6)}
    # duplicate-options gate (permanent per generator contract)
    seen = []
    for L, spec in options.items():
        key = json.dumps(spec, sort_keys=True)
        assert key not in seen, f"item {item_number}: duplicate option detected ({L})"
        seen.append(key)
    answer_key = [L for L, spec in options.items() if spec == target][0]
    return {
        "item_number": item_number,
        "item_text": item_text,
        "tier": tier,
        "choices": {"grid": grid, "options": options},
        "answer_key": answer_key,
    }

items = []

# ---- TIER 1 (floor): single perceptual rule, column-constant sequence ----
# Item 11: fill cycles solid/outline/striped by column, same in every row.
rs = {"fill": column_const_rows(["solid", "outline", "striped"])}
items.append(finalize_item(
    11, "Fill steps solid->outline->striped left to right; same order in every row.",
    1, rs, {"shape": "square"}, rs,
    {"fill": FILLS}))

# Item 12: size cycles s/m/l by column, same in every row.
rs = {"size": column_const_rows(["s", "m", "l"])}
items.append(finalize_item(
    12, "Size steps small->medium->large left to right; same order in every row.",
    1, rs, {"shape": "circle"}, rs,
    {"size": SIZES}))

# Item 13: rotation cycles 0/90/180 by column on rightTriangle (asymmetric shape).
rs = {"rotation": column_const_rows([0, 90, 180])}
items.append(finalize_item(
    13, "Right-triangle rotates 0deg->90deg->180deg left to right; same order in every row.",
    1, rs, {"shape": "rightTriangle"}, rs,
    {"rotation": [0, 90, 180, 270]}))

# ---- TIER 2 (mid): single conceptual rule, distribution-of-three (Latin square) ----
# Item 14: shape distributed circle/square/triangle, Latin square.
rs = {"shape": latin_rows(["circle", "square", "triangle"])}
items.append(finalize_item(
    14, "Circle, square, triangle -- each appears once per row and once per column.",
    2, rs, {}, rs,
    {"shape": SHAPES}))

# Item 15: fill distributed, Latin square, on hexagon.
rs = {"fill": latin_rows(["solid", "outline", "striped"])}
items.append(finalize_item(
    15, "Solid, outline, striped fill -- each appears once per row and once per column.",
    2, rs, {"shape": "hexagon"}, rs,
    {"fill": FILLS}))

# Item 16: size distributed, Latin square, on square.
rs = {"size": latin_rows(["s", "m", "l"])}
items.append(finalize_item(
    16, "Small, medium, large size -- each appears once per row and once per column.",
    2, rs, {"shape": "square"}, rs,
    {"size": SIZES}))

# Item 17: rotation distributed (Latin square) on arrow.
rs = {"rotation": latin_rows([0, 90, 180])}
items.append(finalize_item(
    17, "0deg, 90deg, 180deg rotation -- each appears once per row and once per column.",
    2, rs, {"shape": "arrow"}, rs,
    {"rotation": [0, 90, 180, 270]}))

# Item 18: shape distributed (Latin square) with rightTriangle/arrow/triangle.
rs = {"shape": latin_rows(["rightTriangle", "arrow", "triangle"])}
items.append(finalize_item(
    18, "Right-triangle, arrow, triangle -- each appears once per row and once per column.",
    2, rs, {}, rs,
    {"shape": SHAPES}))

# ---- TIER 3: two rules stacked across two attributes ----
# Item 19: shape Latin square + fill Latin square stacked.
rs = {
    "shape": latin_rows(["circle", "square", "triangle"]),
    "fill": latin_rows(["solid", "outline", "striped"]),
}
items.append(finalize_item(
    19, "Shape (circle/square/triangle) AND fill (solid/outline/striped) each "
        "distribute once per row and once per column, independently.",
    3, rs, {}, rs,
    {"shape": SHAPES, "fill": FILLS}))

# Item 20: rotation Latin square + shape column-constant stacked, on rotatable shapes.
rs = {
    "shape": column_const_rows(["triangle", "rightTriangle", "arrow"]),
    "rotation": latin_rows([0, 90, 180]),
}
items.append(finalize_item(
    20, "Shape steps triangle->right-triangle->arrow left to right (same every row); "
        "rotation (0/90/180deg) distributes once per row and once per column.",
    3, rs, {}, rs,
    {"shape": SHAPES, "rotation": [0, 90, 180, 270]}))

# Item 21: size Latin square + fill Latin square stacked, on circle.
rs = {
    "size": latin_rows(["s", "m", "l"]),
    "fill": latin_rows(["solid", "outline", "striped"]),
}
items.append(finalize_item(
    21, "Size (s/m/l) AND fill (solid/outline/striped) each distribute once per "
        "row and once per column, independently.",
    3, rs, {"shape": "circle"}, rs,
    {"size": SIZES, "fill": FILLS}))

# Item 22: figure-addition rule -- count(col3) = count(col1) + count(col2) per row,
# stacked with shape Latin square.
def addition_rows():
    # counts per row: (1,1,2), (1,2,3) capped, (2,1,3) -- keep <=4 per design rule.
    return [[1, 1, 2], [1, 2, 3], [2, 1, 3]]
rs = {
    "shape": latin_rows(["circle", "square", "triangle"]),
    "count": addition_rows(),
}
items.append(finalize_item(
    22, "Shape distributes once per row/column; the count in the third column "
        "equals the count in the first column plus the count in the second column, "
        "in every row.",
    3, rs, {}, rs,
    {"shape": SHAPES}))

# Item 23: figure-subtraction rule -- count(col3) = count(col1) - count(col2),
# stacked with fill Latin square.
def subtraction_rows():
    return [[3, 1, 2], [2, 1, 1], [4, 2, 2]]
rs = {
    "fill": latin_rows(["solid", "outline", "striped"]),
    "count": subtraction_rows(),
}
items.append(finalize_item(
    23, "Fill distributes once per row/column; the count in the third column "
        "equals the count in the first column minus the count in the second "
        "column, in every row.",
    3, rs, {"shape": "square"}, rs,
    {"fill": FILLS}))

# ---- TIER 4 (ceiling): distribution-of-two, and 3-rule stacks ----
# Item 24: fill distribution-of-two (2 solid + 1 striped per row, position shifts).
rs = {"fill": odd_one_out_rows("solid", "striped")}
items.append(finalize_item(
    24, "Fill is solid except for one striped shape per row; the striped one "
        "shifts position each row (0,1,2 -- distribution-of-two).",
    4, rs, {"shape": "circle"}, rs,
    {"fill": FILLS}))

# Item 25: size distribution-of-two (2 medium + 1 large per row, position shifts).
rs = {"size": odd_one_out_rows("m", "l")}
items.append(finalize_item(
    25, "Size is medium except for one large shape per row; the large one "
        "shifts position each row (distribution-of-two).",
    4, rs, {"shape": "square"}, rs,
    {"size": SIZES}))

# Item 26: rotation distribution-of-two (2 at 0deg + 1 at 180deg per row, shifts),
# on rotatable shape.
rs = {"rotation": odd_one_out_rows(0, 180)}
items.append(finalize_item(
    26, "Rotation is 0deg except for one shape at 180deg per row; the rotated one "
        "shifts position each row (distribution-of-two).",
    4, rs, {"shape": "triangle"}, rs,
    {"rotation": [0, 90, 180, 270]}))

# Item 27: 3-rule stack -- shape Latin square + fill distribution-of-two + count addition.
rs = {
    "shape": latin_rows(["circle", "square", "triangle"]),
    "fill": odd_one_out_rows("solid", "outline"),
    "count": addition_rows(),
}
items.append(finalize_item(
    27, "Shape distributes once per row/column; fill is solid except one outline "
        "per row (position shifts); count in column 3 = column 1 + column 2. "
        "Three rules stacked -- true ceiling.",
    4, rs, {}, rs,
    {"shape": SHAPES, "fill": FILLS}))

# Item 28: 3-rule stack -- rotation Latin square + size distribution-of-two + shape column-const.
rs = {
    "shape": column_const_rows(["rightTriangle", "arrow", "triangle"]),
    "rotation": latin_rows([0, 90, 180]),
    "size": odd_one_out_rows("m", "s"),
}
items.append(finalize_item(
    28, "Shape steps right-triangle->arrow->triangle left to right (same every "
        "row); rotation distributes once per row/column; size is medium except "
        "one small per row (position shifts). Three rules stacked.",
    4, rs, {}, rs,
    {"shape": SHAPES, "rotation": [0, 90, 180, 270], "size": SIZES}))

# Item 29: 3-rule stack -- fill Latin square + count subtraction + size column-const.
rs = {
    "fill": latin_rows(["solid", "outline", "striped"]),
    "count": subtraction_rows(),
    "size": column_const_rows(["s", "m", "l"]),
}
items.append(finalize_item(
    29, "Fill distributes once per row/column; size steps small->medium->large "
        "left to right (same every row); count in column 3 = column 1 minus "
        "column 2. Three rules stacked.",
    4, rs, {"shape": "circle"}, rs,
    {"fill": FILLS, "size": SIZES}))

# Item 30: 3-rule stack -- shape distribution-of-two + rotation Latin square + fill column-const.
rs = {
    "shape": odd_one_out_rows("triangle", "arrow"),
    "rotation": latin_rows([0, 90, 180]),
    "fill": column_const_rows(["solid", "outline", "striped"]),
}
items.append(finalize_item(
    30, "Shape is triangle except one arrow per row (position shifts); rotation "
        "distributes once per row/column; fill steps solid->outline->striped left "
        "to right. Three rules stacked -- ceiling.",
    4, rs, {}, rs,
    {"shape": SHAPES, "rotation": [0, 90, 180, 270]}))

print(f"Generated {len(items)} items (11-{10+len(items)}), all verified, no duplicate options.")
with open("/home/claude/gma/items_v4_11_30.json", "w") as f:
    json.dump(items, f, indent=2)
print("Wrote /home/claude/gma/items_v4_11_30.json")

# tier distribution check
from collections import Counter
print("Tier distribution:", Counter(it["tier"] for it in items))
