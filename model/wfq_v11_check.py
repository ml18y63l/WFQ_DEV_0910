"""V1.1 specification checker: II=5/6, FF read-0, single-port L3 read-1.

Run: py -3 -B model/wfq_v11_check.py
This is a cycle/algorithm model, not synthesizable RTL or an STA test.
Payload sequence numbers below are verification-only identity tags.
"""

from bisect import bisect_right, insort
from collections import Counter
from itertools import product
from random import Random

from wfq_trie_single_copy_check import Trie, le, lt, msb


def verify_search():
    rng = Random(110915)
    sets = [[], [0], [4095], list(range(4096)),
            [0x1FF, 0x250, 0x300], [0x210, 0x250], [0x245, 0x249]]
    sets += [sorted(rng.sample(range(4096), rng.randrange(1, 1024)))
             for _ in range(64)]
    checks = 0
    for values in sets:
        values = sorted(values)
        other = sorted(x ^ 0x555 for x in values)
        for bank in (0, 1):
            tree = Trie([values, other] if bank == 0 else [other, values]).ram
            # Combinational look-ahead encodes each distinct L2 word.
            maxima = [msb(word) for word in tree["L2"]]
            for tag in range(4096):
                a, b, c = tag >> 8, (tag >> 4) & 15, tag & 15
                root = tree["L1"][bank]
                parent = tree["L2"][(bank << 4) | a]
                leaf = tree["L3"][(bank << 8) | (a << 4) | b]
                ca = le(leaf, c) if root & (1 << a) and parent & (1 << b) else None
                bb = lt(parent, b) if root & (1 << a) else None
                ac = lt(root, a)
                for ii in (5, 6):
                    bc = None
                    if ac is not None:
                        bc = (maxima[(bank << 4) | ac] if ii == 5
                              else msb(tree["L2"][(bank << 4) | ac]))
                    if ca is not None:
                        result = (a << 8) | (b << 4) | ca
                    elif bb is not None:
                        result = (a << 8) | (bb << 4) | msb(
                            tree["L3"][(bank << 8) | (a << 4) | bb])
                    elif ac is not None:
                        assert bc is not None
                        result = (ac << 8) | (bc << 4) | msb(
                            tree["L3"][(bank << 8) | (ac << 4) | bc])
                    else:
                        result = None
                    index = bisect_right(values, tag)
                    expected = values[index - 1] if index else None
                    assert result == expected
                    checks += 1
    print(f"Search: {checks:,} query/profile combinations passed")


def schedule(ii, operation):
    if operation == "I":
        return {
            0: [("L3", "R"), ("RC", "R"), ("FREE", "R")],
            ii - 4: [("L3", "R")],
            ii - 3: [("TT", "R")],
            ii - 2: [("NEXT", "R")],
            ii - 1: [(m, "W") for m in ("L3", "RC", "TT", "DATA", "NEXT")],
            ii: [("NEXT", "W")],
        }
    return {
        0: [(m, "R") for m in ("L3", "RC", "DATA", "NEXT")],
        1: [(m, "W") for m in ("L3", "RC", "TT", "FREE")],
    }


def verify_ports():
    checked = 0
    for ii in (5, 6):
        for length in (2, 3, 4):
            for ops in product("IE", repeat=length):
                counts = Counter()
                l3_counts = Counter()
                register_writes = Counter()
                for slot, op in enumerate(ops):
                    for offset, accesses in schedule(ii, op).items():
                        for mem, direction in accesses:
                            edge = slot * ii + offset
                            counts[edge, mem, direction] += 1
                            if mem == "L3":
                                l3_counts[edge] += 1
                    register_writes[slot * ii + (ii - 1 if op == "I" else 1)] += 1
                assert max(counts.values()) <= 1
                assert max(l3_counts.values()) <= 1
                assert max(register_writes.values()) <= 1
                checked += 1
    print(f"Ports: {checked} two/three/four-transaction combinations passed")


class Engine:
    def __init__(self, ii, capacity=64):
        self.ii, self.capacity = ii, capacity
        self.t = 0
        self.last_fire = -ii
        self.ram = {m: {} for m in ("L3", "RC", "TT", "DATA", "NEXT", "FREE")}
        self.ram["FREE"] = dict(enumerate(range(capacity)))
        self.root = [0, 0]
        self.parent = [0] * 32
        self.bank = [{"count": 0}, {"count": 0}]
        self.base = None
        self.head = self.tail = None
        self.cache = None
        self.level = 0
        self.free_count = capacity
        self.reserved = 0
        self.rsp_reserved = 0
        self.responses = []
        self.expected_responses = []
        self.reference = []
        self.active = []
        self.overlays = []
        self.seq = 0
        self.commits = self.accepted = self.consumed = self.raw_hits = 0
        self.accepted_i = self.accepted_e = 0
        self.reads = []
        self.writes = []

    def raw(self, mem, addr):
        return self.ram[mem].get(addr, 0 if mem in ("L3", "RC") else None)

    def logical(self, mem, addr):
        for overlay in reversed(self.overlays):
            if (mem, addr) in overlay["writes"]:
                return overlay["writes"][mem, addr]
        return self.raw(mem, addr)

    def read(self, ctx, label, mem, addr):
        self.reads.append((ctx, label, mem, addr))

    def get(self, ctx, label):
        due, value = ctx["q"][label]
        assert due <= self.t, (self.t, due, label)
        return value

    def can_insert(self, epoch):
        legal = self.level == 0 or epoch in (self.base, (self.base + 1) & 65535)
        return self.free_count > 0 and legal

    def can_extract(self):
        # Admission deliberately does not borrow a same-edge response consume.
        return self.level > 0 and len(self.responses) + self.rsp_reserved < 2

    def accept(self, request):
        op = request[0]
        assert self.t - self.last_fire >= self.ii
        ctx = {"op": op, "start": self.t, "q": {}, "id": self.seq}
        self.seq += 1
        if op == "I":
            _, absolute_epoch, tag, flow = request
            epoch, bank = absolute_epoch & 65535, absolute_epoch & 1
            assert self.can_insert(epoch)
            ctx.update(epoch=epoch, bank=bank, tag=tag, flow=flow,
                       absolute_epoch=absolute_epoch)
            self.read(ctx, "slot", "FREE", self.free_count - 1)
            self.free_count -= 1
            self.reserved += 1
            self.accepted_i += 1
        else:
            assert self.can_extract()
            payload, successor = self.cache
            epoch, tag, flow, _ = payload
            bank = epoch & 1
            ctx.update(epoch=epoch, bank=bank, tag=tag, flow=flow,
                       removed=self.head, payload=payload, successor=successor)
            if successor is not None:
                self.read(ctx, "next_payload", "DATA", successor)
                self.read(ctx, "next_link", "NEXT", successor)
            self.rsp_reserved += 1
            self.accepted_e += 1
        a, b, c = ctx["tag"] >> 8, (ctx["tag"] >> 4) & 15, ctx["tag"] & 15
        ctx.update(a=a, b=b, c=c, old_root=self.root[bank],
                   old_parent=self.parent[(bank << 4) | a])
        self.read(ctx, "leaf", "L3", (bank << 8) | (a << 4) | b)
        self.read(ctx, "rc", "RC", (bank << 12) | ctx["tag"])
        if op == "I":
            ctx["bb"] = (lt(ctx["old_parent"], b)
                         if ctx["old_root"] & (1 << a) else None)
            ctx["ac"] = lt(ctx["old_root"], a)
            if self.ii == 5 and ctx["ac"] is not None:
                # Functional equivalent of parallel max_b[] combinational outputs.
                ctx["bc"] = msb(self.parent[(bank << 4) | ctx["ac"]])
        self.active.append(ctx)
        self.last_fire = self.t
        self.accepted += 1

    def publish(self, ctx, changes):
        self.overlays.append({"id": ctx["id"], "writes": changes})
        self.writes += [(m, a, v) for (m, a), v in changes.items()
                        if not (ctx["op"] == "I" and m == "NEXT" and a == ctx.get("pred"))]
        self.commits += 1

    def insert_commit(self, ctx):
        bank, tag = ctx["bank"], ctx["tag"]
        a, b, c = ctx["a"], ctx["b"], ctx["c"]
        n, pred = self.get(ctx, "slot"), ctx["pred"]
        successor = self.get(ctx, "pred_next") if pred is not None else self.head
        old_rc = self.get(ctx, "rc")
        assert old_rc < self.capacity
        assert ctx["trie_exact"] == (old_rc > 0)
        assert self.root[bank] == ctx["old_root"]
        assert self.parent[(bank << 4) | a] == ctx["old_parent"]
        payload = (ctx["epoch"], tag, ctx["flow"], ctx["id"])
        changes = {
            ("DATA", n): payload, ("NEXT", n): successor,
            ("RC", (bank << 12) | tag): old_rc + 1,
            ("TT", (bank << 12) | tag): n,
        }
        if pred is not None:
            changes["NEXT", pred] = n
            ctx["patch"] = (pred, n)
        if old_rc == 0:
            changes["L3", (bank << 8) | (a << 4) | b] = self.get(ctx, "leaf") | (1 << c)
            self.parent[(bank << 4) | a] |= 1 << b
            self.root[bank] |= 1 << a
        if pred is None:
            self.head, self.cache = n, (payload, successor)
        elif pred == self.head:
            self.cache = (self.cache[0], n)
        if successor is None:
            self.tail = n
        state = self.bank[bank]
        if state["count"] == 0:
            state.update(epoch=ctx["epoch"], head=n, tail=n, minimum=tag, maximum=tag)
        else:
            assert state["epoch"] == ctx["epoch"]
            if tag < state["minimum"]:
                state.update(head=n, minimum=tag)
            if tag >= state["maximum"]:
                state.update(tail=n, maximum=tag)
        state["count"] += 1
        if self.level == 0:
            self.base = ctx["epoch"]
        self.level += 1
        self.reserved -= 1
        insort(self.reference, (ctx["absolute_epoch"], tag, ctx["id"], ctx["flow"]))
        self.publish(ctx, changes)

    def extract_commit(self, ctx):
        bank, tag = ctx["bank"], ctx["tag"]
        a, b, c = ctx["a"], ctx["b"], ctx["c"]
        old_rc = self.get(ctx, "rc")
        assert old_rc > 0
        assert self.head == ctx["removed"]
        assert self.cache[0] == ctx["payload"]
        expected = self.reference.pop(0)
        expected_payload = (expected[0] & 65535, expected[1], expected[3], expected[2])
        assert ctx["payload"] == expected_payload
        self.expected_responses.append(expected_payload)
        self.responses.append(ctx["payload"])
        self.rsp_reserved -= 1
        changes = {
            ("RC", (bank << 12) | tag): old_rc - 1,
            ("FREE", self.free_count): ctx["removed"],
        }
        if old_rc == 1:
            leaf = self.get(ctx, "leaf")
            assert leaf & (1 << c)
            new_leaf = leaf & ~(1 << c)
            changes["L3", (bank << 8) | (a << 4) | b] = new_leaf
            changes["TT", (bank << 12) | tag] = None
            if not new_leaf:
                self.parent[(bank << 4) | a] &= ~(1 << b)
                if not self.parent[(bank << 4) | a]:
                    self.root[bank] &= ~(1 << a)
        self.head = ctx["successor"]
        self.cache = ((self.get(ctx, "next_payload"), self.get(ctx, "next_link"))
                      if self.head is not None else None)
        self.level -= 1
        self.free_count += 1
        state = self.bank[bank]
        state["count"] -= 1
        if state["count"]:
            state.update(head=self.head, minimum=self.cache[0][1])
        else:
            self.bank[bank] = {"count": 0}
        if self.head is None:
            self.tail = None
        else:
            self.base = self.cache[0][0]
        self.publish(ctx, changes)

    def tick(self, request=None, ready=True):
        self.reads, self.writes = [], []
        if request is not None:
            # Check credit before possibly consuming an existing response.
            assert self.can_insert(request[1] & 65535) if request[0] == "I" else self.can_extract()
        if ready and self.responses:
            assert self.responses.pop(0) == self.expected_responses.pop(0)
            self.consumed += 1
        retire = set()
        previous_commits = self.commits
        for ctx in self.active:
            age = self.t - ctx["start"]
            if ctx["op"] == "I":
                if age == 1:
                    leaf = self.get(ctx, "leaf")
                    valid = ctx["old_root"] & (1 << ctx["a"]) and ctx["old_parent"] & (1 << ctx["b"])
                    ctx["ca"] = le(leaf, ctx["c"]) if valid else None
                    if self.ii == 6 and ctx["ac"] is not None:
                        ctx["bc"] = msb(self.parent[(ctx["bank"] << 4) | ctx["ac"]])
                if age == self.ii - 4:
                    prefix = None
                    if ctx["ca"] is None:
                        if ctx["bb"] is not None:
                            prefix = (ctx["a"], ctx["bb"])
                        elif ctx["ac"] is not None:
                            prefix = (ctx["ac"], ctx["bc"])
                    ctx["fallback"] = prefix
                    if prefix is not None:
                        self.read(ctx, "fallback_leaf", "L3",
                                  (ctx["bank"] << 8) | (prefix[0] << 4) | prefix[1])
                if age == self.ii - 3:
                    if ctx["ca"] is not None:
                        key = (ctx["a"] << 8) | (ctx["b"] << 4) | ctx["ca"]
                    elif ctx["fallback"] is not None:
                        low = msb(self.get(ctx, "fallback_leaf"))
                        assert low is not None
                        fa, fb = ctx["fallback"]
                        key = (fa << 8) | (fb << 4) | low
                    else:
                        key = None
                    ctx["pred_key"] = key
                    ctx["trie_exact"] = key == ctx["tag"]
                    if key is not None:
                        self.read(ctx, "tt", "TT", (ctx["bank"] << 12) | key)
                if age == self.ii - 2:
                    if ctx["pred_key"] is not None:
                        pred = self.get(ctx, "tt")
                        assert pred is not None
                    elif self.level and ctx["epoch"] != self.base:
                        pred = self.bank[self.base & 1]["tail"]
                    else:
                        pred = None
                    ctx["pred"] = pred
                    if pred is not None:
                        self.read(ctx, "pred_next", "NEXT", pred)
                if age == self.ii - 1:
                    self.insert_commit(ctx)
                if age == self.ii and "patch" in ctx:
                    self.writes.append(("NEXT", *ctx["patch"]))
                if age == self.ii + 1:
                    retire.add(ctx["id"])
            else:
                if age == 1:
                    self.extract_commit(ctx)
                if age == 2:
                    retire.add(ctx["id"])
        if request is not None:
            self.accept(request)
        counts, l3_count = Counter(), 0
        bus = {(m, a): v for m, a, v in self.writes}
        for ctx, label, mem, addr in self.reads:
            counts[mem, "R"] += 1
            l3_count += mem == "L3"
            value = bus.get((mem, addr), self.logical(mem, addr))
            if mem == "NEXT" and (mem, addr) in bus:
                self.raw_hits += 1
            ctx["q"][label] = (self.t + 1, value)
        for mem, addr, value in self.writes:
            counts[mem, "W"] += 1
            l3_count += mem == "L3"
            self.ram[mem][addr] = value
        assert not counts or max(counts.values()) <= 1, (self.t, counts)
        assert l3_count <= 1
        self.active = [c for c in self.active if c["id"] not in retire]
        self.overlays = [o for o in self.overlays if o["id"] not in retire]
        assert len(self.active) <= 2
        assert self.free_count + self.reserved + self.level == self.capacity
        assert len(self.responses) + self.rsp_reserved <= 2
        assert len(self.reference) == self.level
        if self.commits != previous_commits and (
                self.capacity <= 64 or self.commits % 128 == 0):
            self.check()
        self.t += 1

    def check(self, full=False):
        ordered, addresses = [], []
        p = self.head
        expected_rc, expected_tt = Counter(), {}
        expected_root, expected_parent, expected_leaf = [0, 0], [0] * 32, [0] * 512
        while p is not None:
            assert p not in addresses
            addresses.append(p)
            payload = self.logical("DATA", p)
            ordered.append(payload)
            epoch, tag, _, _ = payload
            bank, a, b, c = epoch & 1, tag >> 8, (tag >> 4) & 15, tag & 15
            key = (bank << 12) | tag
            expected_rc[key] += 1
            expected_tt[key] = p
            expected_root[bank] |= 1 << a
            expected_parent[(bank << 4) | a] |= 1 << b
            expected_leaf[(bank << 8) | (a << 4) | b] |= 1 << c
            p = self.logical("NEXT", p)
        assert ordered == [(e & 65535, t, f, s) for e, t, s, f in self.reference]
        assert self.tail == (addresses[-1] if addresses else None)
        assert self.cache == ((self.logical("DATA", self.head), self.logical("NEXT", self.head))
                              if self.head is not None else None)
        assert self.root == expected_root and self.parent == expected_parent
        assert all(self.logical("L3", a) == v for a, v in enumerate(expected_leaf))
        keys = range(8192) if full else expected_rc
        for key in keys:
            assert self.logical("RC", key) == expected_rc[key]
            assert self.logical("TT", key) == expected_tt.get(key)
        free = [self.logical("FREE", i) for i in range(self.free_count)]
        assert len(set(free)) == len(free) and not (set(free) & set(addresses))
        assert sum(x["count"] for x in self.bank) == self.level
        for bank, state in enumerate(self.bank):
            members = [p for p in addresses if self.logical("DATA", p)[0] & 1 == bank]
            assert len(members) == state["count"]
            if members:
                assert state["head"] == members[0] and state["tail"] == members[-1]
                assert state["minimum"] == self.logical("DATA", members[0])[1]
                assert state["maximum"] == self.logical("DATA", members[-1])[1]
                assert all(self.logical("DATA", p)[0] == state["epoch"] for p in members)

    def command(self, request):
        while self.t - self.last_fire < self.ii:
            self.tick()
        self.tick(request)

    def settle(self):
        while self.active or self.responses:
            self.tick()


def verify_cycle_model(ii):
    engine = Engine(ii)
    for tag in (10, 20, 30):
        engine.command(("I", 65535, tag, tag))
    engine.command(("I", 65535, 25, 25))
    engine.command(("E",))  # Tight NEXT[B] write/read collision.
    engine.settle()
    assert engine.raw_hits > 0
    rng = Random(91500 + ii)
    target = engine.accepted + 10000
    latest_epoch = 65535
    while engine.accepted < target:
        request = None
        if engine.t - engine.last_fire >= ii:
            base_absolute = engine.reference[0][0] if engine.reference else latest_epoch
            epoch = base_absolute + rng.randrange(2)
            latest_epoch = max(latest_epoch, epoch)
            ins_ok = engine.can_insert(epoch & 65535)
            ext_ok = engine.can_extract()
            if ins_ok and (not ext_ok or rng.random() < 0.54):
                request = ("I", epoch, rng.choice((0, 10, 10, 4095, rng.randrange(4096))),
                           rng.randrange(512))
            elif ext_ok:
                request = ("E",)
        engine.tick(request, ready=rng.random() < 0.18)
    engine.settle()
    while engine.level:
        engine.command(("E",))
        engine.settle()
    engine.settle()
    engine.check(full=True)
    assert engine.accepted_i == engine.accepted_e == engine.consumed
    print(f"II={ii}: {engine.accepted:,} accepted mixed/drain operations; "
          f"{engine.raw_hits} same-edge NEXT RAW events; all responses verified")

    full = Engine(ii, 4096)
    for flow in range(4096):
        full.command(("I", 0, 10, flow % 512))
    full.settle()
    assert full.level == 4096 and full.logical("RC", 10) == 4096
    assert full.free_count == 0
    full.check(full=True)
    for _ in range(4096):
        full.command(("E",))
    full.settle()
    full.check(full=True)
    assert full.level == 0 and full.free_count == 4096
    print(f"II={ii}: 4096 identical keys filled and drained, 8192 operations passed")


if __name__ == "__main__":
    verify_search()
    verify_ports()
    for interval in (5, 6):
        verify_cycle_model(interval)
    print("PASS: specification model only; no RTL, RAM-macro simulation, or STA")
