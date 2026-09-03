"""
GMA Section 1 swap, 2026-09-02 (Peter ruling: same 16-item count; replace the
items everyone gets right with harder ones; expand only if spread is still
short at N>=20 on the new set).

RETIRED (p on the first 19 completions of the fixed 16-item set):
  pattern 1 (1.00), pattern 3 (.95), verbal 61 (.95), verbal 67 (1.00)
REPLACED BY: pattern 76, 77 and verbal 78, 79 (this file).

Why these four and not more: an item's contribution to total-score variance
is p(1-p) times its item-total correlation (Nunnally & Bernstein 1994,
Psychometric Theory, ch. 8). At p = 1.00 that is zero; at .95 it is 19% of
the p = .50 maximum; at .84 it is 54%. For a multiple-choice item with
guessing, reliability is maximised when p sits roughly halfway between the
chance rate and 1.0 (Lord 1952, Psychometrika 17:181-194): ~.58 for the
6-option pattern/verbal format used here. The four items at .95-1.00 are the
ones carrying nothing; the .84 numerical trio are the next candidates if
spread is still short.

PATTERN items: same generator contract and rule vocabulary as
tools/gma_generate_v4.py (Carpenter, Just & Shell 1990, Psychological Review
97(3):404-431). Difficulty is driven by the number of rules stacked and the
rule type (Embretson 1998, Psychological Methods 3:380-396: rule count and
abstraction predict matrix-item difficulty in generated banks). Observed on
this bank: 2 rules with one perceptual rule (item 6) = .79; 3 rules (item
10) = .32. Both new items stack 2 CONCEPTUAL rules -- distribution-of-two
(the hardest single CJS rule type) or figure addition -- with a Latin-square
distribution, targeting the ~.50-.60 band between those two anchors.

VERBAL items: classic A:B::C:? analogy (Sternberg 1977). No formal checker
exists for word relations, so the compensating discipline from the
2026-08-01 verbal build applies: exactly one option satisfies the stated
relation, and the item is reviewed to rule out a second defensible answer.
Difficulty is raised the way Bejar, Chaffin & Embretson (1991, Cognitive
and Psychometric Analysis of Analogical Problem Solving, Springer) describe:
a less transparent relation type (characteristic-of, collection-member)
and distractors that are strongly ASSOCIATED with the C term but do not
carry the relation -- the same structure that makes item 71
(Key:Lock::Password:Account, p = .42) discriminate while item 67
(Wheel:Car::Sail:Boat, p = 1.00) does not.
"""
import json, random

random.seed(20260902)

# ---------------------------------------------------------------------------
# Pattern generator helpers -- verbatim from tools/gma_generate_v4.py
# ---------------------------------------------------------------------------
SHAPES = ["circle", "square", "triangle", "rightTriangle", "arrow", "hexagon"]
ROTATABLE_SHAPES = ["triangle", "rightTriangle", "arrow"]
FILLS = ["solid", "outline", "striped"]
SIZES = ["s", "m", "l"]

def cell(shape="circle", fill="solid", size="m", count=1, rotation=0):
    return {"shape": shape, "fill": fill, "size": size, "count": count, "rotation": rotation}

def latin_rows(values3):
    return [values3[i:] + values3[:i] for i in range(3)]

def column_const_rows(values3):
    return [values3[:] for _ in range(3)]

def odd_one_out_rows(majority, minority):
    rows = []
    for shift in range(3):
        row = [majority, majority, majority]
        row[shift] = minority
        rows.append(row)
    return rows

def build_grid(row_specs_by_attr, base=None):
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
    base = base or {}
    expect = dict(shape="circle", fill="solid", size="m", count=1, rotation=0)
    expect.update(base)
    for attr, rows in row_specs_by_attr.items():
        expect[attr] = rows[2][2]
    assert expect == target, f"RULE MISMATCH: derived {expect} != target {target}"

def verify_full_grid(row_specs_by_attr, grid, base=None):
    """Extra pass (contract step 2): re-derive EVERY given cell, not just the
    target, and assert the stored grid matches the rule tables."""
    base = base or {}
    for r in range(3):
        for c in range(3):
            idx = r * 3 + c
            if idx == 8:
                assert grid[idx] is None
                continue
            expect = dict(shape="circle", fill="solid", size="m", count=1, rotation=0)
            expect.update(base)
            for attr, rows in row_specs_by_attr.items():
                expect[attr] = rows[r][c]
            assert grid[idx] == expect, f"GRID MISMATCH at ({r},{c}): {grid[idx]} != {expect}"

def make_distractors(target, rules_used, pool_attr_values):
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
    for i, attr in enumerate(used_attrs[:2]):
        choices = [v for v in pool_attr_values.get(attr, []) if v != target[attr]]
        random.shuffle(choices)
        for v in choices:
            d = dict(target)
            d[attr] = v
            if try_add(f"partial_{i}", d):
                break
    d = dict(target)
    d["count"] = min(4, (d["count"] or 1) + 1) if target["count"] < 4 else max(1, target["count"] - 1)
    try_add("irrelevant", d)
    if target["shape"] in ROTATABLE_SHAPES:
        d = dict(target)
        d["rotation"] = (target["rotation"] + 90) % 360
        try_add("wrong_element", d)
    off_shape = "hexagon" if target["shape"] != "hexagon" else "square"
    try_add("off_vocab", cell(shape=off_shape, fill=target["fill"], size=target["size"],
                               count=target["count"], rotation=0))
    fallback_dims = [
        ("shape", SHAPES), ("fill", FILLS), ("size", SIZES),
        ("rotation", [0, 90, 180, 270]), ("count", [1, 2, 3, 4]),
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
            continue
        try_add(f"fallback_{len(out)}", d)
    assert len(out) == 5, f"only produced {len(out)} unique distractors"
    return out

def rotation_normalised(spec):
    """Op-rule 'never use rotation as a distractor dimension on
    rotation-invariant shapes': two options that differ only by a rotation
    that is invisible on their shape are the same picture."""
    s = dict(spec)
    sym = {"circle": 0, "square": 90, "hexagon": 60}.get(s["shape"])
    if sym == 0:
        s["rotation"] = 0
    elif sym:
        s["rotation"] = (s["rotation"] or 0) % sym
    return json.dumps(s, sort_keys=True)

def finalize_item(item_number, item_text, tier, row_specs, base, rules_used, pool_attr_values):
    grid, target = build_grid(row_specs, base)
    verify(row_specs, target, base)
    verify_full_grid(row_specs, grid, base)
    distractors = make_distractors(target, rules_used, pool_attr_values)
    assert len(distractors) == 5
    letters = ["A", "B", "C", "D", "E", "F"]
    all_opts = list(distractors.values()) + [target]
    random.shuffle(all_opts)
    options = {letters[i]: all_opts[i] for i in range(6)}
    seen = []
    for L, spec in options.items():
        key = json.dumps(spec, sort_keys=True)
        assert key not in seen, f"item {item_number}: duplicate option detected ({L})"
        seen.append(key)
    # rotation-invariance gate (2026-08-05 rule) -- pairwise after normalising
    norm_keys = [rotation_normalised(spec) for spec in options.values()]
    assert len(set(norm_keys)) == 6, f"item {item_number}: two options identical on screen after rotation normalisation"
    answer_key = [L for L, spec in options.items() if spec == target][0]
    # exactly one option matches the target
    assert sum(1 for spec in options.values() if spec == target) == 1
    return {
        "item_number": item_number, "item_text": item_text, "tier": tier,
        "cognitive_domain": "gma_pattern",
        "choices": {"grid": grid, "options": options}, "answer_key": answer_key,
    }

def addition_rows():
    return [[1, 1, 2], [1, 2, 3], [2, 1, 3]]

items = []

# Item 76 -- distribution-of-two (fill) + distribution-of-three (shape). Two
# conceptual rules, one of them the hardest CJS type. Target ~.50.
rs = {
    "shape": latin_rows(["circle", "square", "triangle"]),
    "fill": odd_one_out_rows("solid", "striped"),
}
items.append(finalize_item(
    76, "Shape (circle/square/triangle) appears once per row and once per column; "
        "fill is solid except for exactly one striped shape per row, and the striped "
        "one shifts position each row (distribution-of-two). Two rules stacked.",
    3, rs, {}, rs,
    {"shape": SHAPES, "fill": FILLS}))

# Item 77 -- figure addition (count in column 3 = column 1 + column 2) +
# distribution-of-three (fill), on a fixed shape. Two conceptual rules. Target ~.55-.60.
rs = {
    "fill": latin_rows(["solid", "outline", "striped"]),
    "count": addition_rows(),
}
items.append(finalize_item(
    77, "Fill (solid/outline/striped) appears once per row and once per column; the "
        "count in the third column equals the count in the first column plus the count "
        "in the second column, in every row. Two rules stacked.",
    3, rs, {"shape": "circle"}, rs,
    {"fill": FILLS, "count": [1, 2, 3, 4]}))

# ---------------------------------------------------------------------------
# Verbal analogies -- structured spec + structural gate (no formal checker
# exists for word relations; see module docstring).
# ---------------------------------------------------------------------------
def verbal_item(item_number, a, b, c, answer, relation, lures):
    """lures: list of (word, why_it_tempts). Gates: 6 distinct options, answer
    present exactly once, no option repeats a stem word, no option is a
    case-variant of another, every lure carries a stated reason it does NOT
    satisfy the relation (forces the second-defensible-answer review to be
    written down, not assumed)."""
    options = [answer] + [w for w, _ in lures]
    assert len(options) == 6, f"item {item_number}: need exactly 6 options"
    lowered = [o.lower() for o in options]
    assert len(set(lowered)) == 6, f"item {item_number}: duplicate option"
    stem = {a.lower(), b.lower(), c.lower()}
    assert not (set(lowered) & stem), f"item {item_number}: option repeats a stem word"
    for w, why in lures:
        assert why and len(why) > 15, f"item {item_number}: lure {w} has no rejection reason"
    return {
        "item_number": item_number,
        "item_text": f"{a} is to {b} as {c} is to ___",
        "tier": 3,
        "cognitive_domain": "gma_verbal",
        "relation": relation,
        "choices": options,
        "answer_key": answer,
        "lure_review": {w: why for w, why in lures},
    }

items.append(verbal_item(
    78, "Optimist", "Hope", "Skeptic", "Doubt",
    relation="person : the attitude that defines them",
    lures=[
        ("Trust",     "what a skeptic withholds, not what defines them -- polarity flipped"),
        ("Belief",    "polarity flipped, same trap as Trust"),
        ("Proof",     "what a skeptic demands; an object of the attitude, not the attitude"),
        ("Fear",      "attitude of a pessimist or a worrier, not a skeptic"),
        ("Certainty", "polarity flipped; a skeptic is defined by the absence of it"),
    ]))

items.append(verbal_item(
    79, "Bouquet", "Flower", "Constellation", "Star",
    relation="collection : the member it is made of",
    lures=[
        ("Galaxy",    "a larger collection of stars, not a member of a constellation -- relation runs the wrong way"),
        ("Sky",       "the whole a constellation sits in -- part:whole, wrong direction"),
        ("Planet",    "sky object, but constellations are not made of planets"),
        ("Telescope", "instrument association only"),
        ("Zodiac",    "a collection OF constellations -- wrong direction, same trap as Galaxy"),
    ]))

with open("/home/claude/gma5/items_v5_swap.json", "w") as f:
    json.dump(items, f, indent=2)

# SQL VALUES fragment, generated (never hand-typed JSON).
def sql_str(s):
    return "'" + s.replace("'", "''") + "'"

rows = []
for it in items:
    rows.append("(\n  'newtworks_v2_cognitive_gma', %d, %s,\n  %s::jsonb, %s, %s, 1, true\n)" % (
        it["item_number"], sql_str(it["item_text"]),
        sql_str(json.dumps(it["choices"])), sql_str(it["answer_key"]),
        sql_str(it["cognitive_domain"])))
with open("/home/claude/gma5/items_v5_swap_values.sql", "w") as f:
    f.write(",\n".join(rows) + ";\n")

print(f"Generated {len(items)} items, all verified.")
for it in items:
    print(it["item_number"], it["cognitive_domain"], "answer", it["answer_key"])
