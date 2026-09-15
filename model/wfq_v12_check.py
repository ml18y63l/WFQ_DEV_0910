"""V1.2 capacity/pointer contract and cycle checks.

Run: py -3 -B model/wfq_v12_check.py
Reuses the V1.1 cycle engine, adding explicit finite-width/range checks.
This is not RTL, a fault-controller implementation, macro simulation, or STA.
"""

from random import Random

from wfq_v11_check import Engine, verify_ports


def widths(ptr_width, depth):
    assert 4 <= ptr_width <= 16
    assert 16 <= depth <= 65536 and depth & (depth - 1) == 0
    addr_width = (depth - 1).bit_length()
    assert addr_width <= ptr_width
    return addr_width, depth.bit_length()


def node_address(pointer, ptr_width, depth):
    widths(ptr_width, depth)
    if not isinstance(pointer, int) or not 0 <= pointer < (1 << ptr_width):
        raise ValueError("pointer encoding")
    if pointer >= depth:
        raise ValueError("node pointer out of range before truncation")
    return pointer


def verify_parameters():
    valid = [(10, 1024), (11, 1024), (11, 2048), (12, 4096),
             (4, 16), (5, 16), (16, 65536)]
    for ptr, depth in valid:
        addr, count = widths(ptr, depth)
        assert (1 << addr) == depth and (1 << count) > depth
        assert node_address(depth - 1, ptr, depth) == depth - 1
    invalid = [(9, 1024), (10, 2048), (11, 4096), (11, 1000),
               (11, 0), (11, 8), (17, 1024), (16, 131072)]
    for args in invalid:
        try:
            widths(*args)
        except AssertionError:
            pass
        else:
            raise AssertionError(("illegal parameters accepted", args))
    default_valid = 0
    for pointer in range(1024):
        assert node_address(pointer, 10, 1024) == pointer
        default_valid += 1
    # Host-side values wider than ptr_t must not silently become 10-bit aliases.
    for pointer in (-1, 1024, 1535, 2047):
        try:
            node_address(pointer, 10, 1024)
        except ValueError:
            pass
        else:
            raise AssertionError("value outside 10-bit encoding accepted")
    # The supported wider-pointer configuration has real out-of-range encodings.
    accepted = rejected = 0
    for pointer in range(2048):
        try:
            address = node_address(pointer, 11, 1024)
        except ValueError:
            assert pointer >= 1024
            rejected += 1
        else:
            assert pointer < 1024 and address == pointer
            accepted += 1
    # Dropping bit 10 before validating would alias these to live addresses.
    for pointer in (1024, 1535, 2047):
        assert (pointer & 1023) in range(1024)
        try:
            node_address(pointer, 11, 1024)
        except ValueError:
            pass
        else:
            raise AssertionError("truncation alias was accepted")
    print(f"Parameters: {len(valid)} legal / {len(invalid)} illegal combinations checked")
    print(f"Default 10-bit pointer encodings: {default_valid} valid; all node addresses covered")
    print(f"Wider 11/1024 pointer encodings: {accepted} valid / {rejected} rejected; no truncation alias")


class BoundedEngine(Engine):
    def __init__(self, ii, capacity=1024, ptr_width=10):
        self.ptr_width = ptr_width
        self.addr_width, self.count_width = widths(ptr_width, capacity)
        self.allocated = set()
        super().__init__(ii, capacity)

    def guard_address(self, mem, address):
        depth = {"L3": 512, "TT": 8192, "RC": 8192,
                 "DATA": self.capacity, "NEXT": self.capacity, "FREE": self.capacity}[mem]
        assert isinstance(address, int) and 0 <= address < depth, (mem, address, depth)

    def pointer(self, value, allow_null=True):
        if value is None and allow_null:
            return
        assert node_address(value, self.ptr_width, self.capacity) == value

    def guard_value(self, mem, value):
        if mem in ("TT", "NEXT", "FREE"):
            self.pointer(value, allow_null=mem != "FREE")
        elif mem == "RC":
            assert 0 <= value <= self.capacity and value < (1 << self.count_width)
        elif mem == "L3":
            assert 0 <= value < 65536
        elif mem == "DATA":
            epoch, tag, flow, _sequence = value
            assert 0 <= epoch < 65536 and 0 <= tag < 4096 and 0 <= flow < 512

    def raw(self, mem, addr):
        self.guard_address(mem, addr)
        return super().raw(mem, addr)

    def read(self, ctx, label, mem, addr):
        self.guard_address(mem, addr)
        super().read(ctx, label, mem, addr)

    def get(self, ctx, label):
        value = super().get(ctx, label)
        if label in ("slot", "tt", "pred_next", "next_link"):
            self.pointer(value, allow_null=label not in ("slot", "tt"))
        if label == "slot":
            self.allocated.add(value)
        return value

    def publish(self, ctx, changes):
        for (mem, addr), value in changes.items():
            self.guard_address(mem, addr)
            self.guard_value(mem, value)
        super().publish(ctx, changes)

    def tick(self, request=None, ready=True):
        super().tick(request, ready)
        for mem, addr, value in self.writes:
            self.guard_address(mem, addr)
            self.guard_value(mem, value)
        for value in (self.head, self.tail):
            self.pointer(value)
        if self.cache is not None:
            self.pointer(self.cache[1])
        for state in self.bank:
            assert 0 <= state["count"] <= self.capacity
            if state["count"]:
                self.pointer(state["head"], False)
                self.pointer(state["tail"], False)
        for value in (self.free_count, self.reserved, self.level):
            assert 0 <= value <= self.capacity and value < (1 << self.count_width)


def drain(engine):
    engine.settle()
    while engine.level:
        engine.command(("E",))
        engine.settle()
    engine.check(full=True)
    assert engine.free_count == engine.capacity and engine.reserved == 0
    assert engine.accepted_i == engine.accepted_e == engine.consumed


def verify_full(ii):
    engine = BoundedEngine(ii)
    for flow in range(1024):
        engine.command(("I", 65535, 4095, flow % 512))
    engine.settle()
    engine.check(full=True)
    assert engine.level == 1024 and engine.free_count == 0
    assert engine.logical("RC", 8191) == 1024
    assert not engine.can_insert(65535)
    assert engine.allocated == set(range(1024))
    # Only node arrays shrink: highest metadata address remains usable.
    assert engine.logical("TT", 8191) is not None
    drain(engine)
    assert engine.logical("RC", 8191) == 0 and engine.logical("TT", 8191) is None
    print(f"II={ii}: 1024 identical keys filled/drained, 2048 operations; addresses 0..1023 covered")


def verify_banks(ii):
    engine = BoundedEngine(ii)
    for i in range(512):
        engine.command(("I", 65535, 4095, i))
        engine.command(("I", 65536, 0, i))
    engine.settle()
    assert engine.level == 1024 and [x["count"] for x in engine.bank] == [512, 512]
    engine.command(("E",))
    engine.settle()
    assert engine.level == 1023 and engine.can_insert(0) and not engine.can_insert(1)
    for _ in range(511):
        engine.command(("E",))
    engine.settle()
    assert engine.base == 0 and engine.bank[1]["count"] == 0 and engine.can_insert(1)
    for i in range(512):
        engine.command(("I", 65537, (i * 7) % 4096, i))
    engine.settle()
    engine.check(full=True)
    assert engine.level == 1024
    drain(engine)
    print(f"II={ii}: shared two-bank capacity / third-epoch blocking / bank reuse, 3072 operations passed")


def verify_mixed(ii):
    engine = BoundedEngine(ii)
    for tag in (10, 20, 30, 25):
        engine.command(("I", 65535, tag, tag))
    engine.command(("E",))  # Previous NEXT[B] patch and next-head read share an edge.
    engine.settle()
    assert engine.raw_hits > 0
    rng = Random(120915 + ii)
    target = engine.accepted + 10000
    latest = 65535
    while engine.accepted < target:
        request = None
        if engine.t - engine.last_fire >= ii:
            base = engine.reference[0][0] if engine.reference else latest
            epoch = base + rng.randrange(2)
            latest = max(latest, epoch)
            ins_ok = engine.can_insert(epoch & 65535)
            ext_ok = engine.can_extract()
            if ins_ok and (not ext_ok or rng.random() < 0.58):
                tag = rng.choice((0, 1023, 1024, 2047, 4095, rng.randrange(4096)))
                request = ("I", epoch, tag, rng.randrange(512))
            elif ext_ok:
                request = ("E",)
        engine.tick(request, ready=rng.random() < 0.18)
    drain(engine)
    print(f"II={ii}: {engine.accepted:,} mixed/drain operations; {engine.raw_hits} NEXT RAW events passed")


if __name__ == "__main__":
    verify_parameters()
    verify_ports()
    for interval in (5, 6):
        verify_full(interval)
        verify_banks(interval)
        verify_mixed(interval)
    print("PASS: V1.2 specification checks only; no RTL, fault-controller simulation, or STA")
