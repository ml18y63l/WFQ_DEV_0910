# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spec-first hardware design project for `wfq_tag_sort_engine`: a fully hardware WFQ (Weighted Fair Queuing) finishing-tag sort/extract module for high-speed QoS packet scheduling. It receives `{epoch, 12-bit finishing tag, flow_id}` descriptors already computed by an external Finishing Tag Computation Block, keeps them in a stable sorted order, and pops the minimum on request.

**Current state: documentation only.** No RTL, simulation, synthesis, or STA exists yet (the spec's status line says so explicitly). There is no build system, no git repository, and no build/lint/test commands. Do not claim or assume RTL performance results — target frequencies (250–300 MHz ASIC / 125–150 MHz FPGA) are unverified goals.

All design documents are written in **Simplified Chinese**; keep that language for spec/note edits. Reference papers in `Paper_in_Markdown/` are transcriptions with missing tables/figures/formulas — never use the papers' reported performance numbers as acceptance criteria for this design (explicitly stated in Design_Spec_V1.md §1.3).

## Document Authority & Map

Authority order when texts conflict:

1. **`Design_Spec_V1.md`** — the design baseline. Binding. Its §1.4 lists every point where it corrects the initial draft (e.g. reference counter is 13-bit not 12-bit; explicit 16-bit epoch added; insert commits in 7 cycles; shared issue interval is 8 cycles).
2. **`Initial_Design_Spec.md`** — starting draft (R0). Superseded by V1; historical.
3. **`Paper_in_Markdown/`** — three reference papers by the same research group:
   - `A_Scalable_Packet_Sorting_Circuit.md` (R1): the core architecture being adapted — 3-level Trie, backup search paths, translation table, linked list, duplicate-tag handling (§III-A–III-D).
   - `Fully hardware based WFQ architecture.md` (R2): full-system context; module boundary to the tag computation block; FCFS semantics (§3.1, 3.2).
   - `Design_and_Analysis_of_Matching_Circuit.md` (R3): the Select & Look-Ahead matcher this design adopts (§3.1, 3.2.4).
4. **`Paper_in_Markdown/Important_Notes/`** — design-critical notes:
   - `tag_refcount_array.md` (N1): why per-tag reference counts exist (stale-TT-pointer / wild-pointer prevention on last-of-key dequeue).
   - `finishing_tag_range_wraparound.md` (N2): the 12-bit tag wraparound problem that motivates the epoch scheme.

Spec semantics: in Design_Spec_V1.md, "必须" means a V1 implementation/acceptance requirement; "建议" means an implementation suggestion that may change as long as external behavior is preserved.

## Architecture Big Picture

The module combines four cooperating structures (all synchronous RAMs, read latency = 1):

- **3-level multi-bit Trie** (12-bit tag = 3 × 4-bit literals, 16-way branch per node, one 16-bit bitmap per node): used only to find the insertion predecessor — the largest live key ≤ the new key — in a fixed 3-lookup schedule. Three mutually exclusive candidate classes are evaluated in parallel (A: same leaf prefix; B: same root, smaller parent; C: smaller root), priority A > B > C, so no variable-depth backtracking exists. Each Trie level with multiple readers per cycle is implemented as replicated copies with broadcast writes (L2 ×2, L3 ×3 copies — §6.1 port budget table).
- **Translation Table (TT)**, addressed `{bank, tag}`: points to the *tail* (most recently inserted) node of each duplicate-key group, giving FCFS among equal tags.
- **Reference Count (RC)**, addressed `{bank, tag}`, 13-bit (must represent 4096): decides when the last of a key leaves and Trie markers/TT must be exactly cleared (never clear on first-of-group dequeue).
- **Singly linked sorted list** (separate DATA and NEXT RAMs) + **free-slot stack** + **head cache**: minimum is always the global head; extract reads only the head cache, so dequeue logic commits 1 cycle after acceptance.

**Epoch/bank scheme for tag wraparound**: a 16-bit epoch rides with each descriptor; `bank = epoch[0]`, two banks hold adjacent generations, and one global list keeps the entire old-generation segment before the new-generation segment (a new generation's tag 0 attaches after the old generation's tail). Only two generations may coexist; a third is backpressured. TT/RC/Trie are all per-bank.

**Fixed-latency transaction model** (§10, §11 — the heart of the design): one shared issuer, at most one accepted request (insert or extract) per 8 cycles, at most 2 transactions in execution/writeback. Insert: accepted E0 → logical commit E7 → physical retire E9. Extract: E0 → commit E1 → retire E2. Each transaction accumulates a complete commit descriptor; at commit all architectural state changes atomically, and not-yet-written RAM values live in a logical overlay (newest-committed-write forwarding beats RAM q) so a later transaction's reads always see the earlier transaction's full logical result. The 8-cycle interval is a provable-consistency baseline, not a tunable constant — shortening it invalidates the pointer-release-safety proof (§11.5).

Planned RTL module decomposition (naming in spec §5.2): `wfq_tag_sort_engine.sv` top, plus `wfq_admission_ctrl`, `wfq_epoch_ctrl`, `wfq_trie_search`, `wfq_matcher16`, `wfq_translation_table`, `wfq_tag_refcount_array`, `wfq_list_manager`, `wfq_free_slot_stack`, `wfq_commit_ctrl`, `wfq_sync_ram_1r1w`, `wfq_response_fifo`, `wfq_init_ctrl`.

## Working Rules for This Repo

- **Frozen V1 decisions** are listed in spec §16.2 (epoch scheme, single global list, exact RC deletion, 8-cycle issue interval, 2-entry response FIFO). Anything in §16.3 (e.g. >2 epoch generations, shorter issue interval, same-cycle insert+extract accept, TAG_WIDTH change) requires redesign and a spec update, not a code tweak.
- When editing the spec, keep the requirement-traceability table (§16.1) and the directed-test list F01–F24 (§14.3) in sync with any requirement changes, and update the version/status table at the top of the document.
- Appendix B of the spec is a checklist of the most likely RTL bugs (12-bit counters wrapping at full capacity, TT pointing at group head instead of tail, clearing markers on first-of-group dequeue, missing bank bit in TT/RC addresses, forgetting to patch head_cache.next, etc.) — use it when reviewing any future RTL.
- Appendix C records consistency checks already validated on a throwaway Python model (matcher formulas, A/B/C predecessor classes, port scheduling, 64-slot list model). These cover the spec's logic, not RTL timing.
- Conventions that docs/RTL/waveforms must share: bitmap bit i ↔ literal i (bit 15 = max); NULL pointer is `{valid, ptr}` with no reserved address (0 and 4095 are usable); `free_count + alloc_reserved + queue_level == MEM_DEPTH` at all times; markers/TT/RC are addressed by `{bank, tag}`, never bare tag.
