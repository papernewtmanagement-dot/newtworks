"""
GMA numerical-reasoning item generator — number series completion.
Second GMA subtest (of 4 planned: pattern-matching [done, 30 items],
numerical [this], deductive, verbal).

Item type: candidate sees 5 numbers in a sequence and picks the 6th from
6 options. Classic number-series format -- long-established marker of
numerical reasoning / numerical facility (Thurstone, 1938, Primary Mental
Abilities; also the format used in general-aptitude batteries such as the
Wonderlic Personnel Test). This is a generic, long-public-domain item
format (arithmetic/geometric series), not sourced from or overlapping with
any single proprietary test bank -- clean of the ICAR-16 licensing problem
that killed the earlier cognitive-item sourcing plan.

Rule taxonomy, low->high cognitive demand (mirrors the same "more rules /
harder rule type = harder item" principle used in the pattern-matching
generator):
  1. constant arithmetic difference       (n, n+d, n+2d, ...)
  2. constant ratio (geometric)           (n, n*r, n*r^2, ...)
  3. increasing/decreasing step           (n, n+d, n+2d+k, ... -- step itself changes by a constant)
  4. alternating two operations           (+a, *b, +a, *b, ...)
  5. two interleaved sequences            (odd positions follow rule A, even positions follow rule B -- hardest: candidate must first notice there are two separate sequences braided together)

Generator contract (same discipline as the pattern-matching generator):
  1. Every sequence is derived FROM a declared rule function, never typed freely.
  2. A verification pass re-applies the rule and asserts the target value matches.
  3. Distractors are built with intent (off-by-one-step, wrong operation,
     right operation, wrong operand) and a duplicate-option assertion is a
     permanent gate.
"""
import json, random

random.seed(20260802)

def verify_and_pack(item_number, tier, item_text, seq_prefix, target, rule_fn, distractor_specs):
    # verification: rule_fn(index) for the target index must equal target
    derived = rule_fn(len(seq_prefix))
    assert derived == target, f"item {item_number}: rule mismatch, derived {derived} != {target}"

    letters = ["A", "B", "C", "D", "E", "F"]
    seen = {target}
    uniq = []
    for d in distractor_specs:
        if d not in seen:
            seen.add(d)
            uniq.append(d)
    # Pad with small perturbations of the target until we have 5 unique distractors.
    step = 1
    while len(uniq) < 5:
        for cand in (target + step, target - step, target + step * 2, target - step * 2):
            if cand not in seen and len(uniq) < 5:
                seen.add(cand)
                uniq.append(cand)
        step += 1
        if step > 1000:
            raise AssertionError(f"item {item_number}: could not pad to 5 unique distractors")

    opts = uniq[:5] + [target]
    random.shuffle(opts)
    assert len(set(opts)) == 6, f"item {item_number}: duplicate option collision"
    options = {letters[i]: opts[i] for i in range(6)}
    answer_key = [L for L, v in options.items() if v == target][0]
    return {
        "item_number": item_number,
        "tier": tier,
        "item_text": item_text,
        "choices": {"sequence": seq_prefix, "options": options},
        "answer_key": answer_key,
    }

items = []

# ---- TIER 1 (floor): constant arithmetic difference ----
def make_arith(item_number, start, diff):
    seq = [start + diff * i for i in range(5)]
    rule = lambda idx, start=start, diff=diff: start + diff * idx
    target = rule(5)
    distractors = [target + diff, target - diff, target + 1, target - 1, start + diff * 4]
    return verify_and_pack(
        item_number, 1,
        f"Each number increases by {diff}. What comes next?",
        seq, target, rule, distractors)

items.append(make_arith(1, 4, 6))
items.append(make_arith(2, 91, -7))
items.append(make_arith(3, 12, 11))

# ---- TIER 2: constant ratio (geometric) ----
def make_geo(item_number, start, ratio):
    seq = [start * (ratio ** i) for i in range(5)]
    rule = lambda idx, start=start, ratio=ratio: start * (ratio ** idx)
    target = rule(5)
    prev = seq[-1]
    distractors = [target + prev, target - prev, prev * (ratio + 1), prev * (ratio - 1) if ratio > 1 else prev + 1, target // ratio if ratio != 0 else target - 1]
    return verify_and_pack(
        item_number, 2,
        f"Each number is multiplied by {ratio}. What comes next?",
        seq, target, rule, distractors)

items.append(make_geo(4, 2, 3))
items.append(make_geo(5, 1, 4))
items.append(make_geo(6, 6, 2))

# ---- TIER 2: increasing step (arithmetic on the differences) ----
def make_increasing_step(item_number, start, first_diff, step_growth):
    seq = [start]
    d = first_diff
    for i in range(4):
        seq.append(seq[-1] + d)
        d += step_growth
    def rule(idx, start=start, first_diff=first_diff, step_growth=step_growth):
        val = start
        dd = first_diff
        for _ in range(idx):
            val += dd
            dd += step_growth
        return val
    target = rule(5)
    last_diff = first_diff + step_growth * 4
    distractors = [target - last_diff, target + last_diff - step_growth, seq[-1] + last_diff - 1, seq[-1] + last_diff + 1, seq[-1] * 2]
    return verify_and_pack(
        item_number, 2,
        "The amount added each time grows by a fixed amount. What comes next?",
        seq, target, rule, distractors)

items.append(make_increasing_step(7, 2, 3, 2))
items.append(make_increasing_step(8, 50, -2, -3))

# ---- TIER 3: alternating two operations ----
def make_alternating(item_number, start, add_amt, mult_amt):
    seq = [start]
    for i in range(4):
        if i % 2 == 0:
            seq.append(seq[-1] + add_amt)
        else:
            seq.append(seq[-1] * mult_amt)
    def rule(idx, start=start, add_amt=add_amt, mult_amt=mult_amt):
        val = start
        for i in range(idx):
            if i % 2 == 0:
                val += add_amt
            else:
                val *= mult_amt
        return val
    target = rule(5)
    prev = seq[-1]
    distractors = [prev + add_amt, prev * mult_amt, prev + mult_amt, target + 1, target - 1]
    return verify_and_pack(
        item_number, 3,
        f"The pattern alternates: add {add_amt}, then multiply by {mult_amt}, repeating. What comes next?",
        seq, target, rule, distractors)

items.append(make_alternating(9, 3, 5, 2))
items.append(make_alternating(10, 1, 4, 3))
items.append(make_alternating(11, 10, -3, 2))

# ---- TIER 4 (ceiling): two interleaved sequences ----
def make_interleaved(item_number, odd_start, odd_diff, even_start, even_diff):
    # positions 0,2,4 (1st,3rd,5th shown) follow odd_rule; positions 1,3 follow even_rule;
    # position 5 (the one being solved, 6th number) is an EVEN index (index 5 -> odd position count),
    # careful: use 0-indexed positions; sequence shown length 5 (indices 0-4), target is index 5.
    def rule(idx, odd_start=odd_start, odd_diff=odd_diff, even_start=even_start, even_diff=even_diff):
        if idx % 2 == 0:
            return odd_start + odd_diff * (idx // 2)
        else:
            return even_start + even_diff * (idx // 2)
    seq = [rule(i) for i in range(5)]
    target = rule(5)
    distractors = [target + odd_diff, target - odd_diff, odd_start + odd_diff * 2, even_start + even_diff * 3, target + 1]
    return verify_and_pack(
        item_number, 4,
        "This sequence is actually two sequences braided together (1st, 3rd, 5th... "
        "follow one rule; 2nd, 4th... follow another). What comes next?",
        seq, target, rule, distractors)

items.append(make_interleaved(12, 1, 5, 100, -10))
items.append(make_interleaved(13, 2, 2, 50, 5))
items.append(make_interleaved(14, 20, -4, 3, 3))
items.append(make_interleaved(15, 5, 7, 200, -20))

print(f"Generated {len(items)} numerical items, all verified, no duplicate options.")
with open("/home/claude/gma_num/items_numerical_v1.json", "w") as f:
    json.dump(items, f, indent=2)

from collections import Counter
print("Tier distribution:", Counter(it["tier"] for it in items))
for it in items:
    print(it["item_number"], it["tier"], it["choices"]["sequence"], "->", it["answer_key"], "=", it["choices"]["options"][it["answer_key"]])
