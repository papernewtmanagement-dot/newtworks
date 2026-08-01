"""
GMA deductive-reasoning item generator -- third GMA subtest.
Item type: two premises about three abstract categories (S, M, P), plus a
stated conclusion. Candidate judges whether the conclusion MUST be true,
CANNOT be true, or CAN'T BE DETERMINED from the premises alone.

Content uses abstract/unfamiliar category labels (not real-world claims) by
design -- standard device in reasoning research for isolating logical-form
ability from "belief bias" (judging validity by whether the conclusion
sounds true rather than whether it follows). See Evans, Newstead & Byrne
(1993), Human Reasoning: The Psychology of Deduction, Psychology Press.

VALIDITY IS NOT HAND-JUDGED. Every item's correct answer is computed by a
brute-force finite-model checker below (exhaustive over a small universe),
not the author's own logical intuition -- same discipline as the other GMA
generators. Categorical syllogism background: Copi & Cohen, Introduction to
Logic (11th ed.) -- but the checker, not the textbook, is the actual
authority for each item's answer_key.

Answer distribution is explicitly balanced across all three response
options (not just computed and accepted as-is) -- an unbalanced key lets a
candidate game the test by always picking the majority answer, which would
make the item bank measure nothing.
"""
import json, itertools
from collections import Counter

REGIONS = list(itertools.product([0, 1], repeat=3))  # (inS, inM, inP) per element
ALL_MODELS = list(itertools.product(REGIONS, repeat=4))  # 4-element universe, exhaustive

def holds(assign, kind, X, Y):
    idx = {"S": 0, "M": 1, "P": 2}
    xs = [a[idx[X]] for a in assign]
    ys = [a[idx[Y]] for a in assign]
    if kind == "all":
        return all((not x) or y for x, y in zip(xs, ys))
    if kind == "no":
        return all(not (x and y) for x, y in zip(xs, ys))
    if kind == "some":
        return any(x and y for x, y in zip(xs, ys))
    if kind == "some_not":
        return any(x and not y for x, y in zip(xs, ys))
    raise ValueError(kind)

def evaluate(premise1, premise2, conclusion):
    sat_models = [m for m in ALL_MODELS if holds(m, *premise1) and holds(m, *premise2)]
    if not sat_models:
        return None  # premises jointly unsatisfiable -- unusable item
    truths = {holds(m, *conclusion) for m in sat_models}
    if truths == {True}:
        return "must_be_true"
    if truths == {False}:
        return "cannot_be_true"
    return "cannot_be_determined"

KINDS = ["all", "no", "some", "some_not"]
LABEL = {"all": "All {X} are {Y}.", "no": "No {X} are {Y}.",
         "some": "Some {X} are {Y}.", "some_not": "Some {X} are not {Y}."}

def fmt(stmt):
    kind, X, Y = stmt
    return LABEL[kind].format(X=X, Y=Y)

RESPONSE_OPTIONS = [
    "It must be true.",
    "It cannot be true.",
    "It's impossible to tell from the information given.",
]
ANSWER_TEXT = {
    "must_be_true": "It must be true.",
    "cannot_be_true": "It cannot be true.",
    "cannot_be_determined": "It's impossible to tell from the information given.",
}

# ---- Search all 64 premise/conclusion combinations, bucket by verdict ----
combos_by_verdict = {"must_be_true": [], "cannot_be_true": [], "cannot_be_determined": []}
for k1 in KINDS:
    for k2 in KINDS:
        for k3 in KINDS:
            p1, p2, c = (k1, "S", "M"), (k2, "M", "P"), (k3, "S", "P")
            v = evaluate(p1, p2, c)
            if v:
                combos_by_verdict[v].append((k1, k2, k3))

print("Available combos per verdict:", {k: len(v) for k, v in combos_by_verdict.items()})

# Hand-pick 5 per verdict (15 total), spread across tiers 1-4 by rough
# "premise complexity" (universal+universal=easiest, particular+particular
# =hardest to track), not by verdict (verdict must NOT correlate with tier,
# or tier itself becomes a giveaway).
def complexity(combo):
    k1, k2, k3 = combo
    universality = sum(1 for k in (k1, k2) if k in ("all", "no"))
    return 2 - universality  # 0 = both universal (easy), 2 = both particular (hard)

picks = []
for verdict, combos in combos_by_verdict.items():
    combos_sorted = sorted(set(combos), key=complexity)
    # take a spread: easiest, two mid, two harder
    n = len(combos_sorted)
    idxs = sorted(set([0, n // 4, n // 2, (3 * n) // 4, n - 1]))
    chosen = [combos_sorted[i] for i in idxs][:5]
    while len(chosen) < 5:
        chosen.append(combos_sorted[-1])
    picks.extend([(verdict, c) for c in chosen])

print(f"Picked {len(picks)} items, verdict balance:", Counter(v for v, c in picks))

LABEL_SETS = [
    ("Vindaro", "Kelbit", "Tarnum"), ("Blenthar", "Orvix", "Sammel"),
    ("Quorlin", "Dresta", "Halvox"), ("Prindel", "Wexara", "Norbit"),
    ("Farlin", "Ostrey", "Culmax"), ("Trebond", "Yulara", "Mensiko"),
    ("Kestrel-form", "Voltane", "Ibrina"), ("Zendrick", "Pallux", "Ravorn"),
    ("Drennow", "Sylvex", "Camrith"), ("Untra", "Belmark", "Fosgen"),
    ("Ranthol", "Widget-class", "Corvale"), ("Malren", "Ostwick", "Tavenor"),
    ("Corvid-set", "Halbern", "Nyxara"), ("Prendel", "Vostrik", "Lammar"),
    ("Bexley-group", "Quintar", "Ferrow"),
]

items = []
for i, (verdict, (k1, k2, k3)) in enumerate(picks):
    s, m, p = LABEL_SETS[i]
    premise1, premise2, conclusion = (k1, "S", "M"), (k2, "M", "P"), (k3, "S", "P")
    check = evaluate(premise1, premise2, conclusion)
    assert check == verdict, f"item {i+1}: re-check mismatch {check} != {verdict}"

    # Build text with distinct sentinel tokens (not bare "S"/"M"/"P" letters,
    # which collide with ordinary English words like "Some"/"statement") to
    # avoid corrupting the sentence on substitution.
    def fmt_tok(stmt):
        kind, X, Y = stmt
        return LABEL[kind].format(X="§X§", Y="§Y§").replace("§X§", "%%X%%" if X == "S" else "%%Z%%").replace("§Y§", "%%Y%%" if Y != "S" else "%%X%%")

    # Simpler, robust approach: format directly against token placeholders
    # per statement (S->%%S%%, M->%%M%%, P->%%P%%), independent of which
    # slot is subject/predicate.
    TOKENS = {"S": "%%S%%", "M": "%%M%%", "P": "%%P%%"}
    def fmt_stmt(stmt):
        kind, X, Y = stmt
        return LABEL[kind].format(X=TOKENS[X], Y=TOKENS[Y])

    text = (
        f"{fmt_stmt(premise1)} {fmt_stmt(premise2)} "
        f'Given only this, consider the statement: "{fmt_stmt(conclusion)}" '
        f"What do you know about that statement?"
    )
    text = text.replace("%%S%%", s).replace("%%M%%", m).replace("%%P%%", p)

    tier = 1 + min(3, i // 4)  # spread across 4 tiers roughly evenly, order-based
    items.append({
        "item_number": i + 1,
        "tier": tier,
        "item_text": text,
        "choices": RESPONSE_OPTIONS,
        "answer_key": ANSWER_TEXT[verdict],
        "verdict": verdict,
    })

with open("/home/claude/gma_ded/items_deductive_v1.json", "w") as f:
    json.dump(items, f, indent=2)

print(f"\nFinal: {len(items)} items")
print("Verdict distribution:", Counter(it["verdict"] for it in items))
for it in items:
    print(it["item_number"], it["tier"], it["verdict"], "|", it["item_text"][:110])
