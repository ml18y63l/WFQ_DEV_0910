# Independent re-verification of Design_Spec_V1.md claims (spec review 2026-09-11)
import random

random.seed(20260911)
fails = []

# ---------- 1. Occupancy arithmetic (spec 6.2) ----------
trie = 2*16 + 2*(32*16) + 3*(512*16)
tt = 8192*13; rc = 8192*13; data = 4096*37; nxt = 4096*13; free = 4096*12
total = trie+tt+rc+data+nxt+free
print(f"[1] Trie={trie} TT={tt} RC={rc} DATA={data} NEXT={nxt} FREE={free} total={total} ({total/8/1024:.2f} KiB)")
assert total == 492576 and round(total/8/1024, 2) == 60.13

# ---------- 2. Matcher brute-force reference (spec 7.2) ----------
def m_le(bm, q):
    cand = [i for i in range(16) if (bm >> i) & 1 and i <= q]
    return max(cand) if cand else None
def m_lt(bm, q):
    cand = [i for i in range(16) if (bm >> i) & 1 and i < q]
    return max(cand) if cand else None
def m_max(bm):
    cand = [i for i in range(16) if (bm >> i) & 1]
    return max(cand) if cand else None

# 4x4 Select & Look-Ahead implementation exactly as spec 7.3 formulas
def sla_onehot(c):  # c: 16-bit candidate bitmap -> onehot of max set bit, 0 if none
    G = [ (c >> (4*g)) & 0xF for g in range(4) ]
    S = [ 1 if G[g] and not any(G[h] for h in range(g+1,4)) else 0 for g in range(4) ]
    oh = 0
    for g in range(4):
        if not S[g]: continue
        for j in range(4):
            bit = (G[g] >> j) & 1
            higher = (G[g] >> (j+1)) & (0xF >> (j+1) if j < 3 else 0)
            if bit and higher == 0:
                oh |= 1 << (4*g + j)
    return oh

# verify 7.3 onehot == max set bit of candidate map, exhaustive over all bitmaps
for bm in range(65536):
    oh = sla_onehot(bm)
    ref = 0 if m_max(bm) is None else (1 << m_max(bm))
    if oh != ref:
        fails.append(f"sla bm={bm:#06x}"); break
print("[2] Select&Look-Ahead 4x4 formula: 65536/65536 bitmaps OK" if not fails else f"[2] FAIL {fails[:3]}")

# ---------- 3. A/B/C predecessor classes vs brute force (spec 7.4) ----------
class BankTrie:
    def __init__(self):
        self.L1 = 0
        self.L2 = [0]*16   # L2[a] bitmap over b
        self.L3 = [[0]*16 for _ in range(16)]  # L3[a][b] bitmap over c
    def insert_key(self, y):
        a,b,c = y>>8, (y>>4)&0xF, y&0xF
        self.L1 |= 1<<a; self.L2[a] |= 1<<b; self.L3[a][b] |= 1<<c
    def pred_abc(self, x):
        """Return max live key <= x using ONLY the spec's 3-class 3-lookup scheme."""
        a,b,c = x>>8, (x>>4)&0xF, x&0xF
        # Class A: LE(L3[a][b], c)
        iA = m_le(self.L3[a][b], c)
        # Class B: bB=LT(L2[a],b); cB=MAX(L3[a][bB])
        bB = m_lt(self.L2[a], b)
        iB = None
        if bB is not None:
            cB = m_max(self.L3[a][bB])
            if cB is not None: iB = (a<<8)|(bB<<4)|cB
        # Class C: aC=LT(L1,a); bC=MAX(L2[aC]); cC=MAX(L3[aC][bC])
        aC = m_lt(self.L1, a)
        iC = None
        if aC is not None:
            bC = m_max(self.L2[aC])
            if bC is not None:
                cC = m_max(self.L3[aC][bC])
                if cC is not None: iC = (aC<<8)|(bC<<4)|cC
        if iA is not None: return (a<<8)|(b<<4)|iA, 'A'
        if iB is not None: return iB, 'B'
        if iC is not None: return iC, 'C'
        return None, '-'

sets = [set(), {0}, {4095}, {0,4095}, set(range(4096)),
        {0x1FF,0x250,0x300}, {0x210,0x250}, {0x245,0x249},
        {k for k in range(4096) if (k>>8)==5},          # dense single root branch
        {k*7 % 4096 for k in range(600)},               # scattered
        {k for k in range(0,4096,256)},                 # one per root branch
        ]
for _ in range(40):
    sets.append({random.randrange(4096) for _ in range(random.randrange(1,200))})

checks = mism = 0
for s in sets:
    t = BankTrie()
    for y in s: t.insert_key(y)
    for x in range(4096):
        ref = max((y for y in s if y <= x), default=None)
        got, _cls = t.pred_abc(x)
        checks += 1
        if ref != got:
            mism += 1
            if mism <= 3: fails.append(f"ABC set~{len(s)} x={x:#05x} ref={ref} got={got}")
print(f"[3] A/B/C predecessor vs brute force: {checks} queries, mismatches={mism}")

# ---------- 4. Directed cases F07/F08/F09 ----------
t = BankTrie()
for y in (0x1FF,0x250,0x300): t.insert_key(y)
r,_ = t.pred_abc(0x240); print(f"[4] F07 insert 0x240 -> pred {r:#05x} (expect 0x1FF)"); assert r == 0x1FF
t = BankTrie()
for y in (0x210,0x250): t.insert_key(y)
r,_ = t.pred_abc(0x240); print(f"[4] F08 insert 0x240 -> pred {r:#05x} (expect 0x210)"); assert r == 0x210
t = BankTrie()
for y in (0x245,0x249): t.insert_key(y)
r,_ = t.pred_abc(0x247); print(f"[4] F09 insert 0x247 -> pred {r:#05x} (expect 0x245)"); assert r == 0x245

# ---------- 5. Marker exact-maintenance model: RC-driven invariants (spec 7.1/7.6/8) ----------
class TagState:
    def __init__(self):
        self.RC = [0]*4096
        self.L1 = 0; self.L2=[0]*16; self.L3=[[0]*16 for _ in range(16)]
    def rebuild_expected(self):
        e1 = 0; e2=[0]*16; e3=[[0]*16 for _ in range(16)]
        for tag,rc in enumerate(self.RC):
            if rc:
                a,b,c = tag>>8,(tag>>4)&0xF,tag&0xF
                e1 |= 1<<a; e2[a] |= 1<<b; e3[a][b] |= 1<<c
        return e1,e2,e3
    def check(self):
        e1,e2,e3 = self.rebuild_expected()
        assert self.L1==e1 and self.L2==e2 and self.L3==e3
    def insert(self, tag):
        a,b,c = tag>>8,(tag>>4)&0xF,tag&0xF
        old = self.RC[tag]
        if old == 0:  # spec 7.6: set path
            self.L3[a][b] |= 1<<c; self.L2[a] |= 1<<b; self.L1 |= 1<<a
        self.RC[tag] += 1
    def extract(self, tag):
        a,b,c = tag>>8,(tag>>4)&0xF,tag&0xF
        assert self.RC[tag] > 0
        if self.RC[tag] == 1:  # spec 7.6 cascade, decided by NEW values
            assert self.L3[a][b] & (1<<c)
            new_leaf = self.L3[a][b] & ~(1<<c)
            self.L3[a][b] = new_leaf
            if new_leaf == 0:                       # <=> old_leaf == (1<<c)
                assert self.L2[a] & (1<<b)
                new_parent = self.L2[a] & ~(1<<b)
                self.L2[a] = new_parent
                if new_parent == 0:                 # <=> old_parent == (1<<b)
                    assert self.L1 & (1<<a)
                    self.L1 &= ~(1<<a)
        self.RC[tag] -= 1

st = TagState(); ops = 0
multiset = []
for _ in range(20000):
    if multiset and random.random() < 0.5:
        # extract the current minimum key (head-of-queue semantics: min tag, FCFS within key)
        tag = min(multiset); multiset.remove(tag); st.extract(tag)
    else:
        tag = random.choice([random.randrange(4096)] * 6 + [10]*2 + [4095])  # mix hot keys
        multiset.append(tag); st.insert(tag)
    ops += 1
    if ops % 2000 == 0: st.check()
st.check()
print(f"[5] Exact marker cascade + ==onehot simplification: {ops} random ops, invariants hold, RC sum={sum(st.RC)}=={len(multiset)}")

# ---------- 6. Cycle-table latency/throughput arithmetic (spec 10.2/10.4/10.6/12.2) ----------
assert 8193/250e6*1e6 - 32.772 < 0.01 and 8193/150e6*1e6 - 54.620 < 0.01
for f,agg,direction in [(125e6,15.625e6,7.8125e6),(150e6,18.75e6,9.375e6),
                        (250e6,31.25e6,15.625e6),(300e6,37.5e6,18.75e6)]:
    assert f/8 == agg and f/16 == direction
print("[6] Throughput table + init budget arithmetic OK")

print("\nALL CHECKS PASSED" if not fails else f"\nFAILURES: {fails[:10]}")
