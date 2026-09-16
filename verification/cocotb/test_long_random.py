"""cocotb port-level long-random regression for the WFQ tag sort engine.

Black-box equivalent of the Stage 5 "long" suite (tb_wfq_engine_acceptance.v
RUN_MODE=1, driven by scripts/run_stage5.py --suite long): long random
insert/extract traffic against a stable sorted-queue reference model, full
response scoreboard and protocol checks, observed at the top-level ports only.

Differences from the Verilog testbench (see README.md):
  - Python PRNG stream (same distribution logic, different random traces).
  - Checks are port-level (black box); internal Trie/TT/RC/list images and
    per-edge RAM access schedules are not mirrored here.

Timing model: cycle N starts at rising edge N. Inputs are driven after rising
edge N and sampled settled at falling edge N, so falling-edge samples are the
values captured by rising edge N+1. Commit pulses (registered) are sampled just
after the rising edge that fires them: insert commits fire at accept+4, extract
commits at accept+1.
"""

import os
import random
from bisect import insort
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

PTR_WIDTH = int(os.environ.get("PTR_WIDTH", "10"))
MEM_DEPTH = int(os.environ.get("MEM_DEPTH", "1024"))
FLOW_ID_WIDTH = int(os.environ.get("FLOW_ID_WIDTH", "9"))
SEED = int(os.environ.get("SEED", "12345"))
TARGET = int(os.environ.get("TARGET", "100000"))

EPOCH_MASK = 0xFFFF
TAG_MASK = 0xFFF
FLOW_MASK = (1 << FLOW_ID_WIDTH) - 1


class LongRandom:
    def __init__(self, dut):
        self.dut = dut
        self.model = []                   # sorted (epoch, tag, seq, flow); seq = FCFS order
        self.seq_no = 0
        self.pending_rsp = deque()        # committed, unconsumed (epoch, tag, flow)
        self.ins_ops = deque()            # accepted inserts awaiting their E4 commit
        self.expected_ins = deque()       # edge numbers of expected insert_commit pulses
        self.expected_ext = deque()       # edge numbers of expected extract_commit pulses
        self.contexts = deque()           # (edge, is_insert) live E0..WB windows
        self.insert_accepts = 0
        self.extract_accepts = 0
        self.insert_commits = 0
        self.extract_commits = 0
        self.consumed = 0
        self.segment_accepts = 0
        self.checks = 0
        self.gap5 = 0
        self.peak = 0
        self.edge = 0                     # last completed rising edge number
        self.last_accept_edge = -100
        # driven offer state
        self.insert_val = 0
        self.epoch = 0
        self.tag = 0
        self.flow = 0
        self.extract_req = 0
        self.out_ready = 1
        self._driven = {}                 # last written values, to skip redundant GPI writes
        # events predicted at the falling edge (fire at the next rising edge)
        self.next_insert_accept = False
        self.next_extract_accept = False
        self.next_consume = False
        self.phase = "reset"
        self.rng = None
        self.random_cycles = 0

    # ------------------------------------------------------------------ helpers
    def fail(self, reason):
        head = self.model[0] if self.model else None
        raise AssertionError(
            f"{reason} (edge={self.edge} phase={self.phase} seed={SEED} "
            f"ptr={PTR_WIDTH} depth={MEM_DEPTH} flow={FLOW_ID_WIDTH} "
            f"ins_acc={self.insert_accepts} ext_acc={self.extract_accepts} "
            f"ins_com={self.insert_commits} ext_com={self.extract_commits} "
            f"consumed={self.consumed} nq={len(self.model)} "
            f"held_insert={self.insert_val} epoch={self.epoch} "
            f"held_extract={self.extract_req} "
            f"head={(head[0], head[1]) if head else None} "
            f"ins_ready={int(self.dut.insert_ready.value)} "
            f"ext_ready={int(self.dut.extract_ready.value)} "
            f"epoch_blocked={int(self.dut.insert_epoch_blocked.value)} "
            f"fault={int(self.dut.fault_code.value)})")

    def check(self, ok, reason):
        self.checks += 1
        if not ok:
            self.fail(reason)

    def drive(self, sig, value):
        if self._driven.get(sig._name) != value:
            sig.value = value
            self._driven[sig._name] = value

    # ------------------------------------------------------------------ one cycle
    async def tick(self):
        d = self.dut
        await RisingEdge(d.clk)
        await Timer(1, unit="ns")
        edge = self.edge

        # ---- accepts firing at this edge (predicted at the previous falling edge)
        if self.next_insert_accept:
            self.insert_accepts += 1
            self.ins_ops.append((self.epoch, self.tag, self.seq_no, self.flow))
            self.seq_no += 1
            self.expected_ins.append(edge + 4)
            self.contexts.append((edge, True))
        if self.next_extract_accept:
            self.extract_accepts += 1
            self.expected_ext.append(edge + 1)
            self.contexts.append((edge, False))
            if self.phase == "random":
                self.segment_accepts += 1
        if self.next_insert_accept and self.phase == "random":
            self.segment_accepts += 1

        # ---- commit pulses fired at this edge (registered outputs, visible now)
        exp_ic = bool(self.expected_ins) and self.expected_ins[0] == edge
        exp_ec = bool(self.expected_ext) and self.expected_ext[0] == edge
        self.check(int(d.insert_commit.value) == (1 if exp_ic else 0),
                   "insert_commit pulse schedule (accept+4)")
        self.check(int(d.extract_commit.value) == (1 if exp_ec else 0),
                   "extract_commit pulse schedule (accept+1)")
        if exp_ic:
            self.expected_ins.popleft()
            self.insert_commits += 1
            insort(self.model, self.ins_ops.popleft())
        if exp_ec:
            self.expected_ext.popleft()
            self.extract_commits += 1
            self.check(bool(self.model), "extract committed with live node in model")
            head = self.model.pop(0)
            self.pending_rsp.append((head[0], head[1], head[3]))

        # ---- response consumed at this edge (predicted at the previous falling edge)
        if self.next_consume:
            self.pending_rsp.popleft()
            self.consumed += 1

        # ---- registered outputs / status consistency for this cycle
        nq = len(self.model)
        self.check(int(d.queue_level.value) == nq, "queue_level equals model occupancy")
        self.check(int(d.empty.value) == (1 if nq == 0 else 0), "empty flag")
        reserved = self.insert_accepts - self.insert_commits
        self.check(int(d.full.value) == (1 if nq + reserved == MEM_DEPTH else 0),
                   "full flag (no free slots)")
        has_rsp = bool(self.pending_rsp)
        self.check(int(d.extract_val.value) == (1 if has_rsp else 0),
                   "extract_val equals pending responses")
        if has_rsp:
            e, t, f = self.pending_rsp[0]
            self.check(int(d.min_epoch_out.value) == e and int(d.min_tag_out.value) == t
                       and int(d.min_tag_flow_id.value) == f,
                       "response head order and stability")
        if nq > self.peak:
            self.peak = nq
        self.check(int(d.fault.value) == 0 and int(d.fault_code.value) == 0,
                   "legal traffic must not fault")
        # busy = live E0..WB context; insert window accept..accept+5, extract ..accept+1
        while self.contexts and edge - self.contexts[0][0] >= (6 if self.contexts[0][1] else 2):
            self.contexts.popleft()
        self.check(int(d.busy.value) == (1 if self.contexts else 0), "busy context window")
        model_idle = (not self.contexts and not self.pending_rsp
                      and self.extract_accepts == self.extract_commits)
        self.check(int(d.idle.value) == (1 if model_idle else 0),
                   "idle excludes pending contexts and responses")
        extract_val_cached = has_rsp

        # ---- stimulus for the next rising edge, then drive
        self.stimulus(edge)
        self.drive(d.insert_val, self.insert_val)
        self.drive(d.insert_epoch, self.epoch)
        self.drive(d.insert_tag, self.tag)
        self.drive(d.insert_flow_id, self.flow)
        self.drive(d.extract_req, self.extract_req)
        self.drive(d.extract_out_ready, self.out_ready)

        # ---- falling edge: settled combinational view of the next edge
        await FallingEdge(d.clk)
        await Timer(1, unit="ns")
        self.next_insert_accept = bool(self.insert_val) and int(d.insert_ready.value) == 1
        self.next_extract_accept = bool(self.extract_req) and int(d.extract_ready.value) == 1
        self.check(not (self.next_insert_accept and self.next_extract_accept),
                   "at most one accept per edge")
        self.next_consume = extract_val_cached and self.out_ready == 1
        if self.insert_val:
            head_epoch = self.model[0][0] if self.model else None
            blocked = 1 if (self.model and self.epoch != head_epoch
                            and self.epoch != ((head_epoch + 1) & EPOCH_MASK)) else 0
            self.check(int(d.insert_epoch_blocked.value) == blocked,
                       "epoch backpressure flag")
        if self.next_insert_accept or self.next_extract_accept:
            nxt = edge + 1
            delta = nxt - self.last_accept_edge
            self.check(delta >= 5, f"minimum accepted interval (delta={delta})")
            if delta == 5:
                self.gap5 += 1
            self.last_accept_edge = nxt
        self.edge = edge + 1

    # ------------------------------------------------------------------ stimulus
    def stimulus(self, edge):
        if self.phase == "random":
            self._random_stimulus()
        elif self.phase == "finish":
            self._finish_stimulus()
        else:  # drain / idle wait
            self._drain_stimulus()

    def _random_stimulus(self):
        # Mirrors long_random in tb_wfq_engine_acceptance.v: eight tag
        # distributions rotating every 2000 accepts, ratio variation, epoch
        # window pressure and periodic response backpressure.
        if self.next_insert_accept:
            self.insert_val = 0
        if self.next_extract_accept:
            self.extract_req = 0
        w = self.rng.getrandbits(31)
        generated = self.segment_accepts
        mode_id = (generated // 2000) % 8
        burst = generated % 1000
        nq = len(self.model)
        head = self.model[0][0] if nq else None
        if not self.insert_val:
            if nq > 96:
                offer = (w % 8) == 0
            elif burst < 96:
                offer = (w % 8) < 7
            else:
                offer = (w % 8) < 5
            if offer:
                if nq == 0:
                    self.epoch = (100000 + w % 10000) & EPOCH_MASK
                elif mode_id in (2, 3, 4):
                    self.epoch = (head + (1 if (w >> 9) % 64 == 0 else 0)) & EPOCH_MASK
                else:
                    cw = (w >> 9) % 16
                    self.epoch = (head + (2 if cw == 0 else 1 if cw <= 4 else 0)) & EPOCH_MASK
                if mode_id == 0:
                    self.tag = w & TAG_MASK
                elif mode_id == 1:
                    self.tag = w % 8
                elif mode_id == 2:
                    self.tag = 2047
                elif mode_id == 3:
                    self.tag = generated & TAG_MASK
                elif mode_id == 4:
                    self.tag = (4095 - generated) & TAG_MASK
                elif mode_id == 5:
                    self.tag = 0 if generated % 2 else 4095
                elif mode_id == 6:
                    self.tag = 0x230 + (w % 32)
                else:
                    self.tag = (w % 3) * 1024 + 15
                self.flow = (w >> 12) & FLOW_MASK
                self.insert_val = 1
        if not self.extract_req:
            if nq > 96:
                self.extract_req = 1
            elif burst < 96:
                self.extract_req = 1 if ((w >> 3) % 8) < 2 else 0
            else:
                self.extract_req = 1 if ((w >> 3) % 8) < 6 else 0
        if self.random_cycles % 23 == 0:
            self.out_ready = 1 if ((w >> 6) % 4) != 0 else 0
        self.random_cycles += 1

    def _finish_stimulus(self):
        # Complete outstanding offers without ever withdrawing a valid request:
        # advance the queue to unblock a held insert, feed a filler insert to
        # complete a held extract on an empty queue. The filler needs the
        # "no uncommitted insert" guard (reserved == 0), otherwise it re-offers
        # forever while the previous filler is still between E0 and its E4 commit.
        if self.next_insert_accept:
            self.insert_val = 0
        if self.next_extract_accept:
            self.extract_req = 0
        self.out_ready = 1
        nq = len(self.model)
        head = self.model[0][0] if nq else None
        reserved = self.insert_accepts - self.insert_commits
        if self.insert_val and nq and (nq + reserved >= MEM_DEPTH
                                       or (self.epoch != head
                                           and self.epoch != ((head + 1) & EPOCH_MASK))):
            self.extract_req = 1
        if self.extract_req and nq == 0 and reserved == 0 and not self.insert_val:
            self.insert_val = 1
            self.epoch = (400000 + self.insert_accepts + self.extract_accepts) & EPOCH_MASK
            self.tag = 0
            self.flow = 0

    def _drain_stimulus(self):
        # Safe drain rule: offer extract only when a node will remain for it
        # (live nodes minus extracts already accepted and uncommitted).
        if self.next_insert_accept:
            self.insert_val = 0
        if self.next_extract_accept:
            self.extract_req = 0
        self.out_ready = 1
        inflight = self.extract_accepts - self.extract_commits
        if not self.extract_req and len(self.model) - inflight > 0:
            self.extract_req = 1

    # ------------------------------------------------------------------ main flow
    async def run(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 10, unit="ns").start())
        d.rstn.value = 0
        d.insert_val.value = 0
        d.insert_epoch.value = 0
        d.insert_tag.value = 0
        d.insert_flow_id.value = 0
        d.extract_req.value = 0
        d.extract_out_ready.value = 1
        await Timer(100, unit="ns")
        d.rstn.value = 1
        await Timer(1, unit="ns")

        # Masking is checked pre-edge while init_done is still low; the edge
        # count (release + scan + guard, inclusive) matches the Verilog TB.
        edges = 0
        while int(d.init_done.value) == 0:
            self.check(int(d.insert_ready.value) == 0 and int(d.extract_ready.value) == 0
                       and int(d.extract_val.value) == 0 and int(d.busy.value) == 0
                       and int(d.idle.value) == 0 and int(d.full.value) == 0,
                       "initialization masking")
            await RisingEdge(d.clk)
            await Timer(1, unit="ns")
            edges += 1
            if edges > 65540:
                self.fail("initialization timeout")
        # The exact count depends on the reset-release/clock phase alignment
        # (the Verilog TB pins it exactly); here we bound the scan+guard work.
        scan = MEM_DEPTH if MEM_DEPTH > 8192 else 8192
        self.check(scan <= edges <= scan + 18,
                   f"reset release plus scan and guard edge window (edges={edges})")

        # Phase 1: random traffic until TARGET accepted operations.
        self.phase = "random"
        self.rng = random.Random(SEED)
        watchdog = TARGET * 120 + MEM_DEPTH * 30 + 20000
        next_log = 10000
        while self.segment_accepts < TARGET:
            await self.tick()
            if self.edge > watchdog:
                self.fail("accepted-count random progress watchdog")
            if self.segment_accepts >= next_log:
                d._log.info(f"progress: {self.segment_accepts} accepted ops at edge {self.edge}")
                next_log += 10000

        # Phase 2: complete any held source offers.
        self.phase = "finish"
        guard = MEM_DEPTH * 12 + 400
        while self.insert_val or self.extract_req:
            await self.tick()
            guard -= 1
            if guard < 0:
                self.fail("held source did not complete")

        # Phase 3: drain the queue and all responses.
        self.phase = "drain"
        guard = MEM_DEPTH * 16 + 600
        while (self.model or self.pending_rsp or self.expected_ins or self.expected_ext
               or self.insert_accepts != self.insert_commits
               or self.extract_accepts != self.extract_commits):
            await self.tick()
            guard -= 1
            if guard < 0:
                self.fail("drain timeout")
        for _ in range(10):
            await self.tick()

        # Final invariants.
        self.check(self.segment_accepts >= TARGET, "random segment reached target")
        self.check(self.insert_accepts == self.insert_commits, "all inserts committed")
        self.check(self.extract_accepts == self.extract_commits, "all extracts committed")
        self.check(self.insert_commits == self.extract_commits == self.consumed,
                   "accepts == commits == 2x responses")
        self.check(not self.model and int(d.queue_level.value) == 0 and int(d.empty.value) == 1,
                   "queue drained")
        self.check(int(d.idle.value) == 1, "idle at end")
        self.check(self.gap5 > 0, "gap-5 saturation coverage")
        total = self.insert_accepts + self.extract_accepts
        d._log.info(
            f"PASS cocotb_long_random ptr={PTR_WIDTH} depth={MEM_DEPTH} "
            f"flow={FLOW_ID_WIDTH} seed={SEED} random_accepts={self.segment_accepts} "
            f"accepts={total} responses={self.consumed} cycles={self.edge} "
            f"random_cycles={self.random_cycles} gap5={self.gap5} peak={self.peak} "
            f"checks={self.checks}")


@cocotb.test()
async def long_random(dut):
    """Stage 5 long-suite equivalent: port-level random regression + scoreboard."""
    await LongRandom(dut).run()
