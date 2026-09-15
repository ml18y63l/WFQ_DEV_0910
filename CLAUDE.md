# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spec-first hardware design project for `wfq_tag_sort_engine`: a fully hardware WFQ (Weighted Fair Queuing) finishing-tag sort/extract module for high-speed QoS packet scheduling. It receives `{epoch, 12-bit finishing tag, flow_id}` descriptors already computed by an external Finishing Tag Computation Block, keeps them in a stable sorted order, and pops the minimum on request.

**Current state: specifications and executable Python specification models.** A git repository exists, but no RTL, RTL simulation, synthesis, or STA result exists yet. Run the current capacity/pointer/cycle checks with `py -3 -B model/wfq_v12_check.py` from the repository root. Do not claim RTL performance results — target frequencies (250–300 MHz ASIC / 125–150 MHz FPGA) are unverified goals.

All design documents are written in **Simplified Chinese**; keep that language for spec/note edits. Reference papers in `Paper_in_Markdown/` are transcriptions with missing tables/figures/formulas — never use their reported performance numbers as measured results for this design (Design_Spec_V1.2.md §1.3).

**RTL language is mandatory: Verilog-2001 (IEEE 1364-2001), not SystemVerilog.** Use .v source files and .vh includes. Use reg/wire, fixed-width vectors, module-local constant functions, assign/always @(*) and clocked always blocks. No SystemVerilog types, structs/packages/interfaces, always_comb/always_ff, casts or array ports. Derive ADDR_WIDTH and COUNT_WIDTH as internal localparams using wfq_clog2; do not depend on $clog2. Baseline testbenches use Verilog procedural checks, with Python reference models permitted; they must not require SystemVerilog mode.

**Lifecycle terminology:** use “写回完成” / “writeback complete” for completion of RAM writes plus read-bypass handoff and context release. Use INSERT_WB_DONE_LATENCY / EXTRACT_WB_DONE_LATENCY and E_WB in new specifications/RTL. This event is distinct from logical commit and from the last physical RAM write; keep the specified cycles unchanged.

## Document Authority & Map

Authority order when texts conflict:

1. **`Design_Spec_V1.2.md`** — the current binding baseline. Default PTR_WIDTH=10, MEM_DEPTH=1024; derive ADDR_WIDTH=10 and COUNT_WIDTH=11 separately. Retains single-copy L1/L2 registers, single-copy 1RW L3, and complete issue-interval 5/6 schedules. Section 1.4 explains the capacity/width change and resource tradeoff.
2. **`Design_Spec_V1.1.md`**, **`Design_Spec_V1.md`** and **`Initial_Design_Spec.md`** — historical baselines/draft, superseded by V1.2. Preserve them when implementing the current baseline.
3. **`Paper_in_Markdown/`** — three reference papers by the same research group:
   - `A_Scalable_Packet_Sorting_Circuit.md` (R1): the core architecture being adapted — 3-level Trie, backup search paths, translation table, linked list, duplicate-tag handling (§III-A–III-D).
   - `Fully hardware based WFQ architecture.md` (R2): full-system context; module boundary to the tag computation block; FCFS semantics (§3.1, 3.2).
   - `Design_and_Analysis_of_Matching_Circuit.md` (R3): the Select & Look-Ahead matcher this design adopts (§3.1, 3.2.4).
4. **`Paper_in_Markdown/Important_Notes/`** — design-critical notes:
   - `tag_refcount_array.md` (N1): why per-tag reference counts exist (stale-TT-pointer / wild-pointer prevention on last-of-key dequeue).
   - `finishing_tag_range_wraparound.md` (N2): the 12-bit tag wraparound problem that motivates the epoch scheme.

Supporting reviews: `RAM_Replica_Analysis_0915.md` establishes early exact-leaf access and a single fallback leaf; its synchronous-upper-level II=8 schedule is an intermediate design. `Spec_Review_Analysis_0911.md` records review dispositions. Current V1.2 takes precedence over these notes.

Spec semantics: in Design_Spec_V1.2.md, "必须" means an implementation/acceptance requirement; "建议" means an implementation suggestion that may change while preserving the specified behavior and timing.

## Architecture Big Picture

The module combines four cooperating structures:

- **3-level multi-bit Trie** (12-bit tag = 3 × 4-bit literals, 16-way branch, one 16-bit bitmap per node): finds the largest live same-epoch key ≤ the incoming tag. L1/L2 use one register copy, read latency 0; L3 uses one true 1RW synchronous SRAM, read latency 1. Read the exact leaf at E0, then at most one fallback leaf using A > B > C priority (§7). FAST5 computes each L2 word's MAX in parallel combinational logic, then selects the C candidate; PIPE6 registers aC before selecting/encoding its L2 word. No state mirrors or variable-depth backtracking.
- **Translation Table (TT)**, addressed `{bank, tag}`: points to the *tail* (most recently inserted) node of each duplicate-key group, giving FCFS among equal tags.
- **Reference Count (RC)**, addressed `{bank, tag}`, default 11-bit (must represent 1024): decides when the last of a key leaves and Trie markers/TT must be exactly cleared (never clear on first-of-group dequeue).
- **Singly linked sorted list** (separate DATA and NEXT RAMs) + **free-slot stack** + **head cache**: minimum is always the global head; extract reads only the head cache, so dequeue logic commits 1 cycle after acceptance.

**Epoch/bank scheme for tag wraparound**: a 16-bit epoch rides with each descriptor; `bank = epoch[0]`, two banks hold adjacent generations, and one global list keeps the entire old-generation segment before the new-generation segment (a new generation's tag 0 attaches after the old generation's tail). Only two generations may coexist; a third is backpressured. TT/RC/Trie are all per-bank.

**Capacity and pointer contract** (§2, §6): MEM_DEPTH is independent of PTR_WIDTH; supported depth is a power of two in 16..65536 and ADDR_WIDTH=clog2(MEM_DEPTH)<=PTR_WIDTH. Default nodes use 10-bit RAM addresses, 10-bit pointer fields and 11-bit capacity counters. All 1024 pointer encodings are valid node addresses; link vector retains a separate valid bit (11 bits total). Default pointer field has no bit 10 or binary out-of-range encoding, so its range comparison can fold away. Retain pre-narrowing stack-index checks (fault_code=5) and range checks for wider-pointer configurations (fault_code=7). DATA/NEXT/FREE have exactly 1024 logical rows; TT/RC remain 8192 rows. Derive COUNT_WIDTH from MEM_DEPTH, not pointer width; size arrays by MEM_DEPTH.

**Fixed-latency transaction model** (§10, §11): one shared issuer, at most one accepted request per I cycles, with I=5 by default or I=6 at elaboration. At most 2 execution/writeback contexts. Insert: E0 accept → E_(I-1) commit → E_I predecessor NEXT patch → E_(I+1) writeback complete. Extract: E0 accept → E1 commit → E2 writeback complete. Prepare the commit descriptor body early; complete successor-dependent fields from NEXT q in the cycle immediately before commit. Do not add a full-descriptor register stage before commit. Pending logical writes and same-edge read bypass preserve atomic visibility; specifically cover the preceding insert's NEXT patch overlapping an extract's next-head read. Both intervals have explicit port and pointer-lifetime proofs; arbitrary interval changes require a new design.

At a common frequency, maximum aggregate throughput is f/I; balanced insert-plus-extract packet service is f/(2I). Compare actual synthesized f5/5 and f6/6 rather than assuming FAST5 always wins at different achievable frequencies.

Planned RTL module decomposition (spec §5.2): `wfq_tag_sort_engine.v` top, plus `wfq_admission_ctrl`, `wfq_epoch_ctrl`, `wfq_trie_upper_regs`, `wfq_trie_search`, `wfq_matcher16`, `wfq_translation_table`, `wfq_tag_refcount_array`, `wfq_list_manager`, `wfq_free_slot_stack`, `wfq_commit_ctrl`, `wfq_sync_ram_1rw`, `wfq_sync_ram_1r1w`, `wfq_response_fifo`, `wfq_init_ctrl`.

## Working Rules for This Repo

- **Frozen V1.2 decisions** are listed in spec §16.2 (epoch scheme, stable list, exact deletion, single-copy mixed Trie, complete II=5/6 schedules, two-slot response FIFO, independent capacity/pointer/address/count widths and range checking). Changes in §16.3 require a new spec and proof.
- When editing the current spec, keep the requirement-traceability table (§16.1) and directed-test list F01–F34 (§14.3) in sync, and update the version/status table.
- Appendix B lists common RTL mistakes, including 10-bit counters wrapping at 1024, TT pointing at a group head, premature marker deletion, NEXT/cache forwarding omissions, and truncating invalid pointers into live addresses.
- Appendix C records V1.2 checks: legal/illegal parameter pairs, all 1024 default 10-bit pointer encodings, a separate 2048-encoding check for the wider 11/1024 configuration, 56 port schedules, and default-capacity fill/drain, shared-bank reuse and mixed-cycle tests for both intervals. These are specification-model checks, not RTL fault-controller simulation, macro simulation, STA, or the complete acceptance suite.
- Shared conventions: bitmap bit i ↔ literal i (bit 15=max); NULL is `{valid,ptr}` with no reserved address (0 and 1023 are usable by default); `free_count+alloc_reserved+queue_level==MEM_DEPTH` during initialized normal operation; metadata uses `{bank,tag}`, never bare tag or narrowed node addresses.
