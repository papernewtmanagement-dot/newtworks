import sys, itertools, hashlib, collections
path = sys.argv[1]
bank = {}
for l in open('/home/claude/fc16/statements.txt').read().split('\n'):
    if l:
        f,p,s,d,t = l.split('|',4); bank[s] = (f,p,d,t)
lines = [l for l in open(path).read().split('\n') if l]
assert len(lines) == 192, len(lines)
blocks = collections.defaultdict(list); kinds = {}
for l in lines:
    b,k,f,p,s,d,t = l.split('|',6)
    assert bank[s] == (f,p,d,t), ('statement drifted from bank', s)
    blocks[int(b)].append((f,p,float(d),s)); kinds[int(b)] = k
assert sorted(blocks) == list(range(1,49))
srcs = [l.split('|')[4] for l in lines]
assert len(set(srcs)) == 192 and set(srcs) == set(bank), 'every statement exactly once'
pairs = collections.Counter(); per = collections.defaultdict(lambda:[0,0,0])
ap_spreads=[]; mx_spreads=[]
for b, st in blocks.items():
    assert len(st) == 4
    fs = [x[0] for x in st]; assert len(set(fs)) == 4, ('facet repeat', b)
    ds = [x[2] for x in st]; sp = max(ds)-min(ds)
    if kinds[b] == 'AP':
        assert b <= 32 and all(x[1]=='+' for x in st), ('AP not all positive', b)
        assert sp <= 0.5, ('AP spread', b, sp); ap_spreads.append(sp)
    else:
        assert b >= 33 and sum(x[1]=='+' for x in st) == 2, ('MX not 2+2', b); mx_spreads.append(sp)
    for x in st:
        per[x[0]][0 if kinds[b]=='AP' else (1 if x[1]=='+' else 2)] += 1
    for a,c in itertools.combinations(sorted(fs),2): pairs[(a,c)] += 1
assert all(v == [8,2,2] for v in per.values()), per
assert len(pairs) == 120 and min(pairs.values()) >= 1
print('OK: 48 blocks, 192 statements once each, 16 facets x (8 AP + 2 MX+ + 2 MX-), all text/facet/pole/desirability identical to the live bank')
print('pair coverage:', dict(sorted(collections.Counter(pairs.values()).items())))
print('AP spread max %.2f; MX spread mean %.2f range %.2f-%.2f' % (max(ap_spreads), sum(mx_spreads)/16, min(mx_spreads), max(mx_spreads)))
srt = '\n'.join(sorted(lines, key=lambda x: x.encode()))
print('md5(sorted lines):', hashlib.md5(srt.encode()).hexdigest())
