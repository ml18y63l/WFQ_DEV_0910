"""II=4 feasibility model using a 512x4-bit combinational leaf-maximum summary.

Proposed architecture, NOT V1.2 RTL. Reuses the existing sorted-list oracle and
memory model; replaces insertion scheduling explicitly. The validation L3 read
and speculative TT read both occur at E1. No base-model schedule(ii=4) call is
used: its dict would overwrite accesses when two phases share an edge.
"""
from bisect import bisect_right
from collections import Counter
from itertools import product
from random import Random

from wfq_trie_single_copy_check import Trie, le, lt, msb
from wfq_v12_check import BoundedEngine, drain


def events(op):
    if op == "I":
        return ([(0, m, "R") for m in ("L3", "RC", "FREE")]
                + [(1, "L3", "R"), (1, "TT", "R"), (2, "NEXT", "R")]
                + [(3, m, "W") for m in ("L3", "RC", "TT", "DATA", "NEXT", "UPPER", "MAX")]
                + [(4, "NEXT", "W")])
    return ([(0, m, "R") for m in ("L3", "RC", "DATA", "NEXT")]
            + [(1, m, "W") for m in ("L3", "RC", "TT", "FREE", "UPPER", "MAX")])


def verify_ports():
    checks = 0
    for length in range(2, 6):
        for ops in product("IE", repeat=length):
            for gaps in product((4, 5, 6, 7), repeat=length-1):
                starts = [0]
                for gap in gaps:
                    starts.append(starts[-1] + gap)
                ports, l3_ports = Counter(), Counter()
                for start, op in zip(starts, ops):
                    for offset, mem, direction in events(op):
                        ports[start+offset, mem, direction] += 1
                        if mem == "L3":
                            l3_ports[start+offset] += 1
                assert max(ports.values()) == 1
                assert max(l3_ports.values()) == 1
                for edge in range(starts[-1]+6):
                    live = sum(start <= edge < start+(5 if op == "I" else 2)
                               for start, op in zip(starts, ops))
                    assert live <= 2
                checks += 1
    print(f"Ports: {checks:,} operation/gap schedules; L3 1RW; at most two contexts")


def verify_search():
    rng = Random(40915)
    profiles = [[], [0], [4095], list(range(4096)), [0x1ff, 0x250, 0x300],
                [0x210, 0x250], [0x245, 0x249]]
    profiles += [sorted(rng.sample(range(4096), rng.randrange(1, 1024))) for _ in range(64)]
    checks = 0
    branches = Counter()
    for values in profiles:
        values = sorted(values)
        other = sorted(value ^ 0x555 for value in values)
        for bank in (0, 1):
            ram = Trie([values, other] if bank == 0 else [other, values]).ram
            # Four data bits only: empty is represented as 0 and qualified by L2.
            summary = [msb(word) if word else 0 for word in ram["L3"]]
            parent_max = [msb(word) for word in ram["L2"]]
            for tag in range(4096):
                a, b, c = tag >> 8, (tag >> 4) & 15, tag & 15
                root, parent = ram["L1"][bank], ram["L2"][(bank << 4) | a]
                leaf = ram["L3"][(bank << 8) | (a << 4) | b]
                ca, bb, ac = le(leaf, c), lt(parent, b), lt(root, a)
                prefix = None
                if ca is not None:
                    result, branch = (a << 8) | (b << 4) | ca, "A"
                elif bb is not None:
                    prefix, branch = (a, bb), "B"
                elif ac is not None:
                    prefix, branch = (ac, parent_max[(bank << 4) | ac]), "C"
                else:
                    result, branch = None, "NONE"
                if prefix is not None:
                    fa, fb = prefix
                    address = (bank << 8) | (fa << 4) | fb
                    result = (fa << 8) | (fb << 4) | summary[address]
                    # The E1 physical read validates the summary at E2.
                    assert ram["L3"][address] and msb(ram["L3"][address]) == summary[address]
                position = bisect_right(values, tag)
                assert result == (values[position-1] if position else None)
                branches[branch] += 1
                checks += 1
    assert all(branches[key] for key in ("A", "B", "C", "NONE"))
    print(f"Search: {checks:,} complete-key queries across two banks; {dict(branches)}")


class Summary4Engine(BoundedEngine):
    def __init__(self, capacity=1024, ptr_width=10):
        self.leaf_max = [0] * 512
        self.branches = Counter()
        self.fire_edges = []
        super().__init__(5, capacity, ptr_width)
        self.ii = 4

    def accept(self, request):
        super().accept(request)
        self.fire_edges.append(self.t)
        ctx = self.active[-1]
        if ctx["op"] == "I" and ctx["ac"] is not None:
            ctx["bc"] = msb(self.parent[(ctx["bank"] << 4) | ctx["ac"]])

    def publish(self, ctx, changes):
        for (mem, addr), value in changes.items():
            if mem == "L3":
                self.leaf_max[addr] = msb(value) if value else 0
        super().publish(ctx, changes)

    def check(self, full=False):
        super().check(full)
        for address in range(512):
            leaf = self.logical("L3", address)
            assert self.leaf_max[address] == (msb(leaf) if leaf else 0)

    def tick(self, request=None, ready=True):
        self.reads, self.writes = [], []
        if request is not None:
            # Preserve conservative credit before response consumption.
            assert self.can_insert(request[1] & 65535) if request[0] == "I" else self.can_extract()
        if ready and self.responses:
            assert self.responses.pop(0) == self.expected_responses.pop(0)
            self.consumed += 1
        wb_done = set()
        previous_commits = self.commits
        for ctx in self.active:
            age = self.t - ctx["start"]
            if ctx["op"] == "I":
                if age == 1:
                    leaf = self.get(ctx, "leaf")
                    exact_addr = (ctx["bank"] << 8) | (ctx["a"] << 4) | ctx["b"]
                    assert self.leaf_max[exact_addr] == (msb(leaf) if leaf else 0)
                    ca = le(leaf, ctx["c"])
                    prefix = None
                    if ca is not None:
                        key, branch = (ctx["a"] << 8) | (ctx["b"] << 4) | ca, "A"
                    elif ctx["bb"] is not None:
                        prefix, branch = (ctx["a"], ctx["bb"]), "B"
                    elif ctx["ac"] is not None:
                        assert ctx["bc"] is not None
                        prefix, branch = (ctx["ac"], ctx["bc"]), "C"
                    else:
                        key, branch = None, "NONE"
                    ctx["fallback"] = prefix
                    if prefix is not None:
                        fa, fb = prefix
                        address = (ctx["bank"] << 8) | (fa << 4) | fb
                        ctx["summary_c"] = self.leaf_max[address]
                        key = (fa << 8) | (fb << 4) | ctx["summary_c"]
                        self.read(ctx, "fallback_leaf", "L3", address)
                    ctx["pred_key"], ctx["trie_exact"] = key, key == ctx["tag"]
                    self.branches[branch] += 1
                    if key is not None:
                        self.read(ctx, "tt", "TT", (ctx["bank"] << 12) | key)
                if age == 2:
                    if ctx["fallback"] is not None:
                        leaf = self.get(ctx, "fallback_leaf")
                        assert leaf and msb(leaf) == ctx["summary_c"], "fallback summary mismatch"
                    if ctx["pred_key"] is not None:
                        pred = self.get(ctx, "tt")
                        assert pred is not None
                    elif self.level and ctx["epoch"] != self.base:
                        pred = self.bank[self.base & 1]["tail"]
                    else:
                        pred = None
                    ctx["pred"] = pred
                    self.pointer(pred)
                    if pred is not None:
                        self.read(ctx, "pred_next", "NEXT", pred)
                if age == 3:
                    self.insert_commit(ctx)
                if age == 4 and "patch" in ctx:
                    self.writes.append(("NEXT", *ctx["patch"]))
                if age == 5:
                    wb_done.add(ctx["id"])
            else:
                if age == 1:
                    self.extract_commit(ctx)
                if age == 2:
                    wb_done.add(ctx["id"])
        if request is not None:
            self.accept(request)
        counts, l3_count = Counter(), 0
        for ctx, label, mem, addr in self.reads:
            counts[mem, "R"] += 1
            l3_count += mem == "L3"
            # logical() includes the newest published commit and pending writes.
            value = self.logical(mem, addr)
            if mem == "NEXT" and any(m == mem and a == addr for m, a, _ in self.writes):
                self.raw_hits += 1
            ctx["q"][label] = (self.t + 1, value)
        for mem, addr, value in self.writes:
            self.guard_address(mem, addr)
            self.guard_value(mem, value)
            counts[mem, "W"] += 1
            l3_count += mem == "L3"
            self.ram[mem][addr] = value
        assert not counts or max(counts.values()) <= 1, (self.t, counts)
        assert l3_count <= 1
        self.active = [ctx for ctx in self.active if ctx["id"] not in wb_done]
        self.overlays = [item for item in self.overlays if item["id"] not in wb_done]
        assert len(self.active) <= 2
        assert self.free_count + self.reserved + self.level == self.capacity
        assert len(self.responses) + self.rsp_reserved <= 2
        assert len(self.reference) == self.level
        if self.commits != previous_commits and (self.capacity <= 64 or self.commits % 128 == 0):
            self.check()
        self.t += 1


def verify_cycles():
    for ptr, capacity in ((4, 16), (10, 1024), (11, 1024)):
        engine = Summary4Engine(capacity, ptr)
        # Distinct keys exercise setting and deleting leaf maxima and markers.
        for i in range(capacity):
            engine.command(("I", 65535, (i * 61) % 4096, i % 512))
        engine.settle()
        assert engine.free_count == 0 and engine.allocated == set(range(capacity))
        engine.check(full=True)
        drain(engine)
        assert not any(engine.leaf_max)
        print(f"II=4 capacity: {ptr}/{capacity}, {engine.accepted} fill/drain operations")

    engine = Summary4Engine()
    for i in range(512):
        engine.command(("I", 65535, 4095, i))
        engine.command(("I", 65536, 0, i))
    engine.settle()
    assert engine.logical("RC", 8191) == 512
    assert not engine.can_insert(1)
    for _ in range(512):
        engine.command(("E",))
    engine.settle()
    assert engine.bank[1]["count"] == 0 and engine.can_insert(1)
    for i in range(512):
        engine.command(("I", 65537, i * 7 % 4096, i))
    drain(engine)
    print(f"II=4 epoch: {engine.accepted} duplicate/wrap/bank-reuse operations")

    engine = Summary4Engine(64, 6)
    for tag in (10, 20, 30, 25):
        engine.command(("I", 65535, tag, tag))
    engine.command(("E",))
    engine.settle()
    assert engine.raw_hits > 0
    # Continuously eligible alternating operations prove four-edge issue gaps.
    first = len(engine.fire_edges)
    for i in range(1024):
        engine.command(("I", 65535, i % 4096, i % 512) if i % 2 == 0 else ("E",))
    edges = engine.fire_edges[first:]
    assert all(b-a == 4 for a, b in zip(edges, edges[1:]))
    rng = Random(4091500)
    latest = 65535
    target = engine.accepted + 10000
    while engine.accepted < target:
        request = None
        if engine.t - engine.last_fire >= 4 and rng.random() < 0.75:
            base = engine.reference[0][0] if engine.reference else latest
            epoch = base + rng.randrange(2)
            latest = max(latest, epoch)
            ins_ok, ext_ok = engine.can_insert(epoch & 65535), engine.can_extract()
            if ins_ok and (not ext_ok or rng.random() < 0.53):
                request = ("I", epoch, rng.choice((0, 1023, 1024, 2047, 4095, rng.randrange(4096))),
                           rng.randrange(512))
            elif ext_ok:
                request = ("E",)
        engine.tick(request, ready=rng.random() < 0.18)
    drain(engine)
    print(f"II=4 mixed: {engine.accepted:,} operations, {engine.raw_hits} NEXT RAW events; "
          f"1024 alternating operations at exact II=4; branches={dict(engine.branches)}")

    # A corrupt fallback summary must fail validation before node dereference/commit.
    corrupt = Summary4Engine(16, 4)
    corrupt.command(("I", 0, 0x210, 0))
    corrupt.settle()
    corrupt.leaf_max[0x21] = 7
    corrupt.command(("I", 0, 0x250, 1))
    corrupt.tick()  # E1 speculative TT and validation L3 reads.
    commits = corrupt.commits
    try:
        corrupt.tick()  # E2 validates before NEXT access.
    except AssertionError as error:
        assert str(error) == "fallback summary mismatch"
        assert corrupt.commits == commits and not corrupt.reads and not corrupt.writes
    else:
        raise AssertionError("corrupt summary escaped validation")
    print("Summary corruption: detected at E2 before NEXT read or new commit (model assertion)")


if __name__ == "__main__":
    verify_ports()
    verify_search()
    verify_cycles()
    print("PASS: proposed II=4 architecture model only; no modified RTL, macro timing, or STA")
