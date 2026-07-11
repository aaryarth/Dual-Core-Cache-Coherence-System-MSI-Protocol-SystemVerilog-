# Dual-Core Cache Coherence System — MSI Protocol (SystemVerilog)

A snooping-bus MSI cache-coherence implementation for a dual-core system,
with a self-checking testbench. Written in SystemVerilog and verified with
Icarus Verilog (`iverilog`/`vvp`).

## Files

| File                    | Description                                                        |
|--------------------------|---------------------------------------------------------------------|
| `msi_pkg.sv`             | Shared types: MSI states (I/S/M), bus commands, parameters          |
| `main_memory.sv`         | Single-ported shared main memory (combinational read, sync write)   |
| `cache_core.sv`          | Per-core direct-mapped L1 cache + MSI FSM + snoop responder          |
| `coherence_bus.sv`       | Snooping bus arbiter (round-robin) + memory tie-in                  |
| `dual_core_msi_top.sv`   | Top level: 2× `cache_core` + `coherence_bus`                        |
| `tb_dual_core_msi.sv`    | Self-checking testbench (12 scenarios, 45 checks)                   |

## Architecture

- **Cache**: 4-line direct-mapped, 32-bit data, 8-bit address
  (`idx = addr[1:0]`, `tag = addr[7:2]`) — easy to resize via `msi_pkg.sv`.
- **Coherence protocol**: classic 3-state MSI.
  - `PrRd` miss → `BusRd`  → line goes to **S**
  - `PrWr` hit on **S**    → `BusUpgr` → line goes to **M**, invalidates other cache
  - `PrWr` miss             → `BusRdX` → line goes to **M**, invalidates other cache
  - Dirty (`M`) line evicted on a conflicting-tag miss → silent `BusWB` writeback
  - Remote `BusRd` snooping an `M` line → owner supplies data + downgrades to **S**
  - Remote `BusRdX`/`BusUpgr` snooping any valid line → invalidates it
- **Bus**: single shared bus, one transaction at a time, round-robin
  arbitration between the two cores when both request simultaneously.

## Running the simulation (Icarus Verilog)

```bash
iverilog -g2012 -o sim.vvp msi_pkg.sv main_memory.sv cache_core.sv \
         coherence_bus.sv dual_core_msi_top.sv tb_dual_core_msi.sv
vvp sim.vvp
```

You should see `RESULTS: 45 PASSED, 0 FAILED, 0 INVARIANT VIOLATIONS`.

The testbench also writes `wave.vcd`, viewable with GTKWave:
```bash
gtkwave wave.vcd
```

This also works unmodified in other simulators (Questa/VCS/Xcelium) since it
only uses standard SystemVerilog constructs.

## What the testbench actually verifies

1. **Reset state** — all lines start Invalid.
2. **Cold read miss** (I→S) with correct data from memory.
3. **Shared read** — a second core reading the same line does *not* invalidate
   the first (both end up S).
4. **Write hit / upgrade** (S→M via `BusUpgr`) — correctly invalidates the
   remote sharer.
5. **Write miss with dirty-line eviction** — forces an implicit `BusWB`
   writeback of a *different* dirty line before installing the new one;
   checked directly against the memory array.
6. **Cache hit accounting** — re-reading a just-installed line hits with
   *zero* new bus transactions (checked via a live transaction counter).
7. **Remote read of a Modified line** — forces writeback + M→S downgrade on
   the owner, and delivers the up-to-date dirty value to the requester.
8. **Bus transaction count** — an end-to-end sanity check that the total
   number of arbitrated bus transactions matches the hand-traced protocol
   sequence.
9. **True concurrent contention** — both cores issue a request in the exact
   same clock cycle; verifies the round-robin arbiter serializes them
   correctly and both eventually complete with correct data.
10. **Background MSI invariant monitor** — runs every clock cycle for the
    entire simulation, independent of the directed scenarios: for any
    address held by both caches, it flags a violation if one core is in `M`
    while the other is not `I` (the fundamental MSI mutual-exclusion rule).

### Note on the concurrency scenario

Scenario 11 (true same-cycle contention) actually caught a genuine RTL bug
during development: the bus's memory-write logic wasn't gated to the `BMEM`
state, so on two back-to-back transactions with *different* snoop outcomes,
stale snoop-result registers from the previous transaction could briefly
leak through and corrupt an unrelated memory address. It's fixed in
`coherence_bus.sv` (see the comment there) — a good example of why
concurrent/back-to-back stress scenarios matter even after directed tests
all pass.

## Resume bullet suggestions

- Implemented a snooping-based MSI cache-coherence mechanism for a dual-core
  system in SystemVerilog, including a round-robin bus arbiter and
  dirty-line eviction/writeback handling.
- Developed a self-checking verification testbench (12 scenarios, 45
  assertions) validating MSI state transitions, read/write hits and misses,
  inter-core invalidation/downgrade, and a cycle-accurate background
  invariant monitor for MSI mutual exclusion — which surfaced and helped
  root-cause a real RTL race condition under concurrent bus contention.

