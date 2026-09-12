#!/usr/bin/env python3
"""Assemble 48 four-statement ranking blocks from the 192 kept statements.

Structure (matches the 75-block assembly of record, scaled to 16 facets):
  32 all-positive (AP) blocks + 16 mixed (MX) blocks, 2 positive + 2 negative each.
  Every facet: 12 statements = 8 AP + 2 MX-positive + 2 MX-negative appearances.
Hard constraints:
  H1 four distinct facets in every block
  H2 AP block desirability spread (max-min) <= 0.5
  H3 MX block = exactly 2 '+' and 2 '-'  (held by construction)
Soft objective:
  S1 facet-pair coverage: every one of the 120 pairs co-occurs 2-3 times
     (48 blocks x 6 pairs = 288 pairings / 120 pairs = 2.4 mean)
  S2 MX desirability: small spread, positives close to each other, negatives close
     (Cao & Drasgow 2019: faking resistance is greatest when a block is balanced)
The split of each facet's positives into MX vs AP is decided by the search, with S2
pulling the low-desirability positives into the mixed blocks.
"""
import random, math, sys, itertools, hashlib

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 1
ITERS = int(sys.argv[2]) if len(sys.argv) > 2 else 3_000_000
random.seed(SEED)

rows = []
for l in open('/home/claude/fc16/statements.txt').read().split('\n'):
    if not l:
        continue
    facet, pole, src, des, txt = l.split('|', 4)
    rows.append(dict(facet=facet, pole=pole, src=src, des=float(des), des_s=des, txt=txt))
N = len(rows)
assert N == 192
facets = sorted({r['facet'] for r in rows})
assert len(facets) == 16
fidx = {f: i for i, f in enumerate(facets)}
for r in rows:
    r['f'] = fidx[r['facet']]

N_AP, N_MX = 32, 16
H = 1000.0          # hard-constraint weight
W_MX = 3.0          # MX desirability weight
W_ONE, W_ZERO = 10.0, 100.0   # pair coverage penalties
W_S = 2.0                     # split preference: MX positives = low end of the facet

# --- initial split: two lowest-desirability positives per facet -> MX, rest -> AP
pos_by_f = {f: sorted([i for i, r in enumerate(rows) if r['f'] == f and r['pole'] == '+'],
                      key=lambda i: (rows[i]['des'], rows[i]['src'])) for f in range(16)}
neg_by_f = {f: [i for i, r in enumerate(rows) if r['f'] == f and r['pole'] == '-'] for f in range(16)}
# Pins forced by the desirability floor of the bank (see notes in the report):
#   political 512B 5.00 / 590B 5.67, friendliness 510A 5.00, proactive 548A 5.33 have no
#   AP companions within 0.5 -> must be MX. political 586B / N074 (both 6.00) must then be AP,
#   and their only possible companions within 0.5 are ach 590A, asser 583B, ent 586A/593A/546A,
#   caut 596A, disp N042 -> those stay AP (their facets send higher positives to MX).
PIN_MX = {'512B', '590B', '510A', '548A'}
PIN_AP = {'586B', 'N074', '590A', '583B', '586A', '593A', '596A', 'N042'}
bysrc = {r['src']: i for i, r in enumerate(rows)}
mx_pos, ap_pool = [], []
for f in range(16):
    order = [i for i in pos_by_f[f] if rows[i]['src'] in PIN_MX] + \
            [i for i in pos_by_f[f] if rows[i]['src'] not in PIN_MX and rows[i]['src'] not in PIN_AP] + \
            [i for i in pos_by_f[f] if rows[i]['src'] in PIN_AP]
    mx_pos += order[:2]
    ap_pool += order[2:]
pinned = {bysrc[s] for s in PIN_MX | PIN_AP}
assert all(rows[i]['src'] not in PIN_AP for i in mx_pos)
assert all(rows[i]['src'] not in PIN_MX for i in ap_pool)
mx_neg = [i for f in range(16) for i in neg_by_f[f]]
assert len(mx_pos) == 32 and len(ap_pool) == 128 and len(mx_neg) == 32

# blocks: list of lists of statement idx. AP blocks 0..31, MX blocks 32..47
ap_pool.sort(key=lambda i: rows[i]['des'])          # desirability-sorted deal -> near-feasible spread
blocks = [ap_pool[k*4:(k+1)*4] for k in range(N_AP)]
random.shuffle(mx_pos); random.shuffle(mx_neg)
for k in range(N_MX):
    blocks.append([mx_pos[2*k], mx_pos[2*k+1], mx_neg[2*k], mx_neg[2*k+1]])
where = {}
for b, blk in enumerate(blocks):
    for i in blk:
        where[i] = b

def block_cost(blk, is_ap):
    fs = [rows[i]['f'] for i in blk]
    c = H * (4 - len(set(fs)))
    ds = [rows[i]['des'] for i in blk]
    if is_ap:
        spread = max(ds) - min(ds)
        if spread > 0.5 + 1e-9:
            c += H * (1 + (spread - 0.5) / 0.33)
    else:
        ps = sorted(rows[i]['des'] for i in blk if rows[i]['pole'] == '+')
        ns = sorted(rows[i]['des'] for i in blk if rows[i]['pole'] == '-')
        sp = max(ds) - min(ds); c += W_MX * (sp * sp / 3.0 + 0.5 * ((ps[1] - ps[0]) + (ns[1] - ns[0])))
    return c

def pair_pen(cnt):
    if cnt == 0: return W_ZERO
    if cnt == 1: return W_ONE
    if cnt <= 3: return 0.0
    return 5.0 * (cnt - 3) ** 2

def block_pairs(blk):
    fs = sorted(rows[i]['f'] for i in blk)
    return [(a, b) for a, b in itertools.combinations(fs, 2) if a != b]

pc = {}
for a in range(16):
    for b in range(a+1, 16):
        pc[(a, b)] = 0
for blk in blocks:
    for p in block_pairs(blk):
        pc[p] += 1

fmin = {f: min(rows[i]['des'] for i in pos_by_f[f] if rows[i]['src'] not in PIN_AP) for f in range(16)}
_bc = block_cost
def block_cost(blk, is_ap):
    c = _bc(blk, is_ap)
    if not is_ap:
        c += W_S * sum(rows[i]['des'] - fmin[rows[i]['f']] for i in blk if rows[i]['pole'] == '+')
    return c
bcost = [block_cost(blk, b < N_AP) for b, blk in enumerate(blocks)]
total = sum(bcost) + sum(pair_pen(v) for v in pc.values())

def try_swap(b1, i1, b2, i2, T):
    """swap statement i1 (in block b1) with i2 (in block b2); metropolis accept."""
    global total
    old1, old2 = blocks[b1], blocks[b2]
    op1, op2 = block_pairs(old1), block_pairs(old2)
    new1 = [i2 if x == i1 else x for x in old1]
    new2 = [i1 if x == i2 else x for x in old2]
    np1, np2 = block_pairs(new1), block_pairs(new2)
    # pair delta
    delta = 0.0
    touched = {}
    for p in op1 + op2:
        touched[p] = touched.get(p, 0) - 1
    for p in np1 + np2:
        touched[p] = touched.get(p, 0) + 1
    for p, d in touched.items():
        if d:
            delta += pair_pen(pc[p] + d) - pair_pen(pc[p])
    nc1 = block_cost(new1, b1 < N_AP); nc2 = block_cost(new2, b2 < N_AP)
    delta += (nc1 - bcost[b1]) + (nc2 - bcost[b2])
    if delta <= 0 or random.random() < math.exp(-delta / T):
        blocks[b1], blocks[b2] = new1, new2
        bcost[b1], bcost[b2] = nc1, nc2
        for p, d in touched.items():
            pc[p] += d
        where[i1], where[i2] = b2, b1
        total += delta
        return True
    return False

T0, T1 = 30.0, 0.05
best = (total, [b[:] for b in blocks])
for it in range(ITERS):
    T = T0 * (T1 / T0) ** (it / ITERS)
    m = random.random()
    if m < 0.55:                       # AP <-> AP
        b1, b2 = random.sample(range(N_AP), 2)
        i1, i2 = random.choice(blocks[b1]), random.choice(blocks[b2])
    elif m < 0.75:                     # MX <-> MX same pole
        b1, b2 = random.sample(range(N_AP, N_AP + N_MX), 2)
        pole = '+' if random.random() < 0.5 else '-'
        i1 = random.choice([i for i in blocks[b1] if rows[i]['pole'] == pole])
        i2 = random.choice([i for i in blocks[b2] if rows[i]['pole'] == pole])
    else:                              # same-facet positive MX <-> AP (changes the split)
        b1 = random.randrange(N_AP, N_AP + N_MX)
        i1 = random.choice([i for i in blocks[b1] if rows[i]['pole'] == '+'])
        f = rows[i1]['f']
        if i1 in pinned:
            continue
        cands = [i for i in pos_by_f[f] if where[i] < N_AP and i not in pinned]
        if not cands:
            continue
        i2 = random.choice(cands)
        b2 = where[i2]
    try_swap(b1, i1, b2, i2, T)
    if total < best[0] - 1e-9:
        best = (total, [b[:] for b in blocks])

total, blocks = best

# ---- validate + report
viol = []
for b, blk in enumerate(blocks):
    fs = [rows[i]['f'] for i in blk]
    if len(set(fs)) != 4: viol.append(f'block {b+1} repeats a facet')
    ds = [rows[i]['des'] for i in blk]
    if b < N_AP:
        if any(rows[i]['pole'] != '+' for i in blk): viol.append(f'AP block {b+1} has a negative')
        if max(ds) - min(ds) > 0.5 + 1e-9: viol.append(f'AP block {b+1} spread {max(ds)-min(ds):.2f}')
    else:
        if sum(rows[i]['pole'] == '+' for i in blk) != 2: viol.append(f'MX block {b+1} not 2+2')
used = sorted(i for blk in blocks for i in blk)
if used != list(range(N)): viol.append('not every statement used exactly once')
for f in range(16):
    ap = sum(1 for b in range(N_AP) for i in blocks[b] if rows[i]['f'] == f)
    mp = sum(1 for b in range(N_AP, 48) for i in blocks[b] if rows[i]['f'] == f and rows[i]['pole'] == '+')
    mn = sum(1 for b in range(N_AP, 48) for i in blocks[b] if rows[i]['f'] == f and rows[i]['pole'] == '-')
    if (ap, mp, mn) != (8, 2, 2): viol.append(f'{facets[f]} split {ap}/{mp}/{mn}')

pcount = {}
for a in range(16):
    for b in range(a+1, 16): pcount[(a, b)] = 0
for blk in blocks:
    for p in block_pairs(blk): pcount[p] += 1
dist = {}
for v in pcount.values(): dist[v] = dist.get(v, 0) + 1
ap_spreads = [max(rows[i]['des'] for i in blocks[b]) - min(rows[i]['des'] for i in blocks[b]) for b in range(N_AP)]
mx_spreads = [max(rows[i]['des'] for i in blocks[b]) - min(rows[i]['des'] for i in blocks[b]) for b in range(N_AP, 48)]
sd = {}
for s in ap_spreads:
    k = round(s, 2); sd[k] = sd.get(k, 0) + 1
mx_pos_des = [rows[i]['des'] for b in range(N_AP, 48) for i in blocks[b] if rows[i]['pole'] == '+']
bank_pos = [r['des'] for r in rows if r['pole'] == '+']
# which facets deviate from "two lowest positives -> MX"
dev = []
for f in range(16):
    lowest2 = set(pos_by_f[f][:2])
    inmx = {i for b in range(N_AP, 48) for i in blocks[b] if rows[i]['f'] == f and rows[i]['pole'] == '+'}
    if inmx != lowest2:
        dev.append((facets[f], sorted((rows[i]['src'], rows[i]['des_s']) for i in inmx),
                    sorted((rows[i]['src'], rows[i]['des_s']) for i in lowest2)))

print(f'seed {SEED} iters {ITERS} objective {total:.2f} violations {len(viol)}')
for v in viol: print('  VIOL', v)
print('pair coverage (times co-occurring -> number of pairs):', dict(sorted(dist.items())))
print('AP spread distribution:', dict(sorted(sd.items())))
print(f'MX spread mean {sum(mx_spreads)/16:.2f} range {min(mx_spreads):.2f}-{max(mx_spreads):.2f}')
print(f'MX positives mean des {sum(mx_pos_des)/32:.2f} vs bank positives {sum(bank_pos)/160:.2f}')
print('facets whose MX positives are not their two lowest:')
for d in dev: print('  ', d[0], 'MX=', d[1], 'lowest2=', d[2])

# ---- write assembly lines: block|kind|facet|pole|source|desirability|statement
out = []
for b, blk in enumerate(blocks):
    kind = 'AP' if b < N_AP else 'MX'
    order = sorted(blk, key=lambda i: (0 if rows[i]['pole'] == '+' else 1, -rows[i]['des'], rows[i]['src']))
    for i in order:
        r = rows[i]
        out.append(f"{b+1}|{kind}|{r['facet']}|{r['pole']}|{r['src']}|{r['des_s']}|{r['txt']}")
open(f'/home/claude/fc16/assembly_seed{SEED}.txt', 'w').write('\n'.join(out) + '\n')
srt = '\n'.join(sorted(out, key=lambda x: x.encode()))
print('lines', len(out), 'md5(sorted)', hashlib.md5(srt.encode()).hexdigest())
