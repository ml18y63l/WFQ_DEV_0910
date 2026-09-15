"""Check a proposed single-copy Trie schedule, not RTL or the frozen V1.

Run from the project root:
    py -3 model/wfq_trie_single_copy_check.py

E0 reads the exact L1/L2/L3 addresses. E1 optionally reads a lower-root
L2 node. E2 reads at most one fallback leaf. The predecessor is ready
for the TT address at E3. All reads require one edge before consumption.
"""

from bisect import bisect_right
from collections import Counter
from dataclasses import dataclass
from itertools import product
from random import Random


def msb(value):
    return value.bit_length() - 1 if value else None


def lt(bitmap, query):
    return msb(bitmap & ((1 << query) - 1))


def le(bitmap, query):
    return msb(bitmap & ((1 << (query + 1)) - 1))


@dataclass(frozen=True)
class ReadResult:
    ready_edge: int
    value: int

    def consume(self, edge):
        assert edge >= self.ready_edge, (edge, self.ready_edge)
        return self.value


class Trie:
    def __init__(self, bank_values):
        self.ram = {"L1": [0] * 2, "L2": [0] * 32, "L3": [0] * 512}
        for bank, values in enumerate(bank_values):
            for tag in values:
                a, b, c = tag >> 8, (tag >> 4) & 15, tag & 15
                self.ram["L1"][bank] |= 1 << a
                self.ram["L2"][(bank << 4) | a] |= 1 << b
                self.ram["L3"][(bank << 8) | (a << 4) | b] |= 1 << c

    def predecessor(self, bank, tag):
        used = set()
        trace = []

        def read(edge, memory, address):
            assert (edge, memory) not in used
            used.add((edge, memory))
            trace.append((edge, memory, address))
            return ReadResult(edge + 1, self.ram[memory][address])

        a, b, c = tag >> 8, (tag >> 4) & 15, tag & 15
        # E0: independent addresses are known directly from the input tag.
        root_q = read(0, "L1", bank)
        parent_q = read(0, "L2", (bank << 4) | a)
        exact_leaf_q = read(0, "L3", (bank << 8) | (a << 4) | b)

        # E1: consume E0 reads; save exact-path values for the E7 update.
        root = root_q.consume(1)
        parent = parent_q.consume(1)
        exact_leaf = exact_leaf_q.consume(1)
        exact_path = bool(root & (1 << a)) and bool(parent & (1 << b))
        c_a = le(exact_leaf, c) if exact_path else None
        b_b = lt(parent, b) if root & (1 << a) else None
        a_c = lt(root, a)
        lower_parent_q = None
        if c_a is None and b_b is None and a_c is not None:
            lower_parent_q = read(1, "L2", (bank << 4) | a_c)

        # E2: A wins immediately; otherwise B exists iff its parent bit
        # exists. Only if B is absent do we need a lower-root candidate.
        fallback_leaf_q = None
        fallback_prefix = None
        if c_a is not None:
            selected = "A"
        elif b_b is not None:
            selected = "B"
            fallback_prefix = (a, b_b)
        elif lower_parent_q is not None:
            selected = "C"
            b_c = msb(lower_parent_q.consume(2))
            assert b_c is not None  # Root marker implies nonempty parent.
            fallback_prefix = (a_c, b_c)
        else:
            selected = "NONE"
        if fallback_prefix is not None:
            fa, fb = fallback_prefix
            fallback_leaf_q = read(
                2, "L3", (bank << 8) | (fa << 4) | fb
            )

        # E3: predecessor can drive the TT request at this edge.
        if selected == "A":
            result = (a << 8) | (b << 4) | c_a
        elif fallback_leaf_q is not None:
            fc = msb(fallback_leaf_q.consume(3))
            assert fc is not None  # Parent marker implies nonempty leaf.
            fa, fb = fallback_prefix
            result = (fa << 8) | (fb << 4) | fc
        else:
            result = None
        assert sum(memory == "L2" for _, memory, _ in trace) <= 2
        assert sum(memory == "L3" for _, memory, _ in trace) <= 2
        return result, selected


def check_predecessor():
    rng = Random(20260915)
    value_sets = [
        [], [0], [4095], list(range(4096)),
        [0x1FF, 0x250, 0x300], [0x210, 0x250], [0x245, 0x249],
    ]
    value_sets += [
        sorted(rng.sample(range(4096), rng.randrange(1, 1024)))
        for _ in range(64)
    ]
    checked = 0
    coverage = Counter()
    for values in value_sets:
        values = sorted(values)
        other_bank = sorted(tag ^ 0x555 for tag in values)
        for bank in (0, 1):
            banks = [values, other_bank] if bank == 0 else [other_bank, values]
            trie = Trie(banks)
            for query in range(4096):
                index = bisect_right(values, query)
                expected = values[index - 1] if index else None
                result, selected = trie.predecessor(bank, query)
                assert result == expected, (bank, query, result, expected)
                coverage[selected] += 1
                checked += 1
    assert set(coverage) == {"A", "B", "C", "NONE"}
    print(f"Predecessor: {checked:,} queries passed; {dict(coverage)}")
    print("Read latency: no value consumed before its one-cycle return")
    print("Search ports: at most one read per level per edge")


INSERT = {
    0: [("L1", "R"), ("L2", "R"), ("L3", "R"), ("RC", "R"), ("FREE", "R")],
    1: [("L2", "R")],
    2: [("L3", "R")],
    3: [("TT", "R")],
    4: [("NEXT", "R")],
    7: [(name, "W") for name in ("L1", "L2", "L3", "RC", "TT", "DATA", "NEXT")],
    8: [("NEXT", "W")],
}
EXTRACT = {
    0: [(name, "R") for name in ("L1", "L2", "L3", "RC", "DATA", "NEXT")],
    1: [(name, "W") for name in ("L1", "L2", "L3", "RC", "TT", "FREE")],
}


def check_schedule():
    checked = 0
    for length in (2, 3):
        for ops in product(("I", "E"), repeat=length):
            per_direction = Counter()
            trie_total = Counter()
            for position, op in enumerate(ops):
                schedule = INSERT if op == "I" else EXTRACT
                for relative_edge, accesses in schedule.items():
                    edge = 8 * position + relative_edge
                    for memory, direction in accesses:
                        per_direction[edge, memory, direction] += 1
                        if memory in ("L1", "L2", "L3"):
                            trie_total[edge, memory] += 1
            assert max(per_direction.values()) <= 1, ops
            # True single-port means R+W <= 1, stronger than 1R1W.
            assert max(trie_total.values()) <= 1, ops
            checked += 1
    print(f"Schedule: {checked} two/three-transaction combinations passed")
    print("L1/L2/L3: true 1RW sufficient; other memories stay within V1 1R1W")


def check_storage():
    old = 2 * 16 + 2 * 32 * 16 + 3 * 512 * 16
    new = 2 * 16 + 32 * 16 + 512 * 16
    saved = old - new
    new_total = 492576 - saved
    assert (old, new, saved, new_total) == (25632, 8736, 16896, 475680)
    print(f"Trie bits: {old:,} -> {new:,}; saved {saved:,} bits ({saved//8:,} bytes)")
    print(f"Counted storage excluding staging: {new_total:,} bits, {new_total/8192:.3f} KiB")


if __name__ == "__main__":
    check_predecessor()
    check_schedule()
    check_storage()
    print("PASS: algorithm and schedule only; no RTL simulation or STA")
