//=============================================================================
// tb_dual_core_msi.sv
// Self-checking verification testbench for the dual-core MSI coherence
// system. Covers:
//   - Read miss  (I -> S)
//   - Shared read (S -> S, no invalidation)
//   - Write hit / upgrade (S -> M, invalidates remote sharer)
//   - Write miss with dirty-line eviction + implicit writeback (BusWB)
//   - Remote read of a Modified line (forces writeback + downgrade M -> S)
//   - Cache hit (no bus transaction) verification via transaction counter
//   - A continuously-running MSI mutual-exclusion invariant monitor
//=============================================================================
`timescale 1ns/1ps

module tb_dual_core_msi;

  import msi_pkg::*;

  // ------------------------------------------------------------------
  // Clock / reset
  // ------------------------------------------------------------------
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  // ------------------------------------------------------------------
  // DUT connections
  // ------------------------------------------------------------------
  logic                    p0_req_valid, p1_req_valid;
  pr_op_t                  p0_req_op,    p1_req_op;
  logic [ADDR_WIDTH-1:0]   p0_req_addr,  p1_req_addr;
  logic [DATA_WIDTH-1:0]   p0_req_wdata, p1_req_wdata;
  logic                    p0_req_ready, p1_req_ready;
  logic                    p0_resp_valid,p1_resp_valid;
  logic [DATA_WIDTH-1:0]   p0_resp_rdata,p1_resp_rdata;
  logic                    p0_resp_hit,  p1_resp_hit;

  logic [NUM_LINES-1:0][1:0]            dbg_state0_packed;
  logic [NUM_LINES-1:0][TAG_WIDTH-1:0]  dbg_tag0_packed;
  logic [NUM_LINES-1:0][DATA_WIDTH-1:0] dbg_data0_packed;
  logic [NUM_LINES-1:0][1:0]            dbg_state1_packed;
  logic [NUM_LINES-1:0][TAG_WIDTH-1:0]  dbg_tag1_packed;
  logic [NUM_LINES-1:0][DATA_WIDTH-1:0] dbg_data1_packed;
  logic [31:0]             stat_transactions;

  // Unpacked local mirrors used throughout the checks below, kept in sync
  // combinationally from the packed DUT debug ports.
  msi_state_t              dbg_state0 [NUM_LINES];
  logic [TAG_WIDTH-1:0]    dbg_tag0   [NUM_LINES];
  logic [DATA_WIDTH-1:0]   dbg_data0  [NUM_LINES];
  msi_state_t              dbg_state1 [NUM_LINES];
  logic [TAG_WIDTH-1:0]    dbg_tag1   [NUM_LINES];
  logic [DATA_WIDTH-1:0]   dbg_data1  [NUM_LINES];

  always_comb begin
    for (int i = 0; i < NUM_LINES; i++) begin
      dbg_state0[i] = msi_state_t'(dbg_state0_packed[i]);
      dbg_tag0[i]   = dbg_tag0_packed[i];
      dbg_data0[i]  = dbg_data0_packed[i];
      dbg_state1[i] = msi_state_t'(dbg_state1_packed[i]);
      dbg_tag1[i]   = dbg_tag1_packed[i];
      dbg_data1[i]  = dbg_data1_packed[i];
    end
  end

  dual_core_msi_top dut (
    .clk (clk), .rst_n (rst_n),

    .p0_req_valid(p0_req_valid), .p0_req_op(p0_req_op),
    .p0_req_addr (p0_req_addr),  .p0_req_wdata(p0_req_wdata),
    .p0_req_ready(p0_req_ready), .p0_resp_valid(p0_resp_valid),
    .p0_resp_rdata(p0_resp_rdata), .p0_resp_hit(p0_resp_hit),

    .p1_req_valid(p1_req_valid), .p1_req_op(p1_req_op),
    .p1_req_addr (p1_req_addr),  .p1_req_wdata(p1_req_wdata),
    .p1_req_ready(p1_req_ready), .p1_resp_valid(p1_resp_valid),
    .p1_resp_rdata(p1_resp_rdata), .p1_resp_hit(p1_resp_hit),

    .dbg_state0_packed(dbg_state0_packed), .dbg_tag0_packed(dbg_tag0_packed), .dbg_data0_packed(dbg_data0_packed),
    .dbg_state1_packed(dbg_state1_packed), .dbg_tag1_packed(dbg_tag1_packed), .dbg_data1_packed(dbg_data1_packed),
    .stat_transactions(stat_transactions)
  );

  // ------------------------------------------------------------------
  // Scoreboard bookkeeping
  // ------------------------------------------------------------------
  int pass_count = 0;
  int fail_count = 0;

  task automatic check_eq(input string what, input logic [63:0] actual,
                           input logic [63:0] expected);
    if (actual === expected) begin
      pass_count++;
      $display("  [PASS] %-45s actual=0x%0h", what, actual);
    end else begin
      fail_count++;
      $display("  [FAIL] %-45s actual=0x%0h expected=0x%0h", what, actual, expected);
    end
  endtask

  function automatic string state_str(input msi_state_t s);
    case (s)
      I_STATE: return "I";
      S_STATE: return "S";
      M_STATE: return "M";
      default: return "?";
    endcase
  endfunction

  task automatic check_state(input string what, input msi_state_t actual,
                              input msi_state_t expected);
    if (actual === expected) begin
      pass_count++;
      $display("  [PASS] %-45s state=%s", what, state_str(actual));
    end else begin
      fail_count++;
      $display("  [FAIL] %-45s state=%s expected=%s", what, state_str(actual), state_str(expected));
    end
  endtask

  // ------------------------------------------------------------------
  // Background invariant monitor: MSI mutual exclusion.
  // For any line index shared by both direct-mapped caches with the SAME
  // tag (i.e. genuinely the same memory address):
  //   - at most one cache may be in M
  //   - if one cache is in M, the other MUST be I
  // This runs every cycle for the whole simulation.
  // ------------------------------------------------------------------
  int invariant_violations = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      for (int k = 0; k < NUM_LINES; k++) begin
        if (dbg_tag0[k] == dbg_tag1[k]) begin
          if ((dbg_state0[k] == M_STATE) && (dbg_state1[k] != I_STATE)) begin
            invariant_violations++;
            $display("  [INVARIANT VIOLATION] t=%0t line=%0d core0=M while core1=%s",
                      $time, k, state_str(dbg_state1[k]));
          end
          if ((dbg_state1[k] == M_STATE) && (dbg_state0[k] != I_STATE)) begin
            invariant_violations++;
            $display("  [INVARIANT VIOLATION] t=%0t line=%0d core1=M while core0=%s",
                      $time, k, state_str(dbg_state0[k]));
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Driver tasks
  // ------------------------------------------------------------------
  task automatic do_op(input int core_sel, input pr_op_t op,
                        input logic [ADDR_WIDTH-1:0] addr,
                        input logic [DATA_WIDTH-1:0] wdata,
                        output logic [DATA_WIDTH-1:0] rdata,
                        output logic hit);
    begin
      if (core_sel == 0) begin
        @(posedge clk);
        while (!p0_req_ready) @(posedge clk);
        p0_req_valid <= 1'b1;
        p0_req_op    <= op;
        p0_req_addr  <= addr;
        p0_req_wdata <= wdata;
        @(posedge clk);
        p0_req_valid <= 1'b0;
        while (!p0_resp_valid) @(posedge clk);
        rdata = p0_resp_rdata;
        hit   = p0_resp_hit;
      end else begin
        @(posedge clk);
        while (!p1_req_ready) @(posedge clk);
        p1_req_valid <= 1'b1;
        p1_req_op    <= op;
        p1_req_addr  <= addr;
        p1_req_wdata <= wdata;
        @(posedge clk);
        p1_req_valid <= 1'b0;
        while (!p1_resp_valid) @(posedge clk);
        rdata = p1_resp_rdata;
        hit   = p1_resp_hit;
      end
      // allow snoop-response pipeline to settle before the next op is checked
      @(posedge clk);
    end
  endtask

  // ------------------------------------------------------------------
  // Test addresses
  //   ADDR_WIDTH=8, LINE_IDX_BITS=2  =>  idx = addr[1:0], tag = addr[7:2]
  // ------------------------------------------------------------------
  localparam logic [ADDR_WIDTH-1:0] ADDR_A    = 8'h04; // idx0 tag1
  localparam logic [ADDR_WIDTH-1:0] ADDR_B    = 8'h08; // idx0 tag2 (aliases with A -> evicts it)
  localparam logic [ADDR_WIDTH-1:0] ADDR_E    = 8'h05; // idx1 tag1 (independent line)

  logic [DATA_WIDTH-1:0] rdata;
  logic                  hit;
  int                    exp_tx;

  initial begin
    p0_req_valid = 0; p0_req_op = PR_RD; p0_req_addr = 0; p0_req_wdata = 0;
    p1_req_valid = 0; p1_req_op = PR_RD; p1_req_addr = 0; p1_req_wdata = 0;
    exp_tx = 0;

    $display("================================================================");
    $display(" Dual-Core MSI Cache Coherence -- Self-Checking Testbench");
    $display("================================================================");

    // Reset
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ---- Sanity: all lines start Invalid ----
    $display("\n-- Scenario 0: Reset state --");
    for (int k = 0; k < NUM_LINES; k++) begin
      check_state($sformatf("core0 line%0d reset state", k), dbg_state0[k], I_STATE);
      check_state($sformatf("core1 line%0d reset state", k), dbg_state1[k], I_STATE);
    end

    // ---- Scenario 1: core0 read miss on A ----
    $display("\n-- Scenario 1: core0 PrRd(A) -- cold read miss --");
    do_op(0, PR_RD, ADDR_A, '0, rdata, hit); exp_tx++;
    check_eq   ("core0 read miss returns mem[A]=4", rdata, 32'h4);
    check_eq   ("core0 read miss reported as MISS", hit, 1'b0);
    check_state("core0 line0 state after read miss", dbg_state0[0], S_STATE);
    check_eq   ("core0 line0 tag after read miss",    dbg_tag0[0],   1);

    // ---- Scenario 2: core1 read miss on A (should stay Shared, no invalidation of core0) ----
    $display("\n-- Scenario 2: core1 PrRd(A) -- shared read, no invalidation --");
    do_op(1, PR_RD, ADDR_A, '0, rdata, hit); exp_tx++;
    check_eq   ("core1 read returns mem[A]=4",     rdata, 32'h4);
    check_state("core1 line0 state after read",    dbg_state1[0], S_STATE);
    check_state("core0 line0 STILL Shared (no inv)",dbg_state0[0], S_STATE);

    // ---- Scenario 3: core0 write hit on Shared line -> BusUpgr -> invalidates core1 ----
    $display("\n-- Scenario 3: core0 PrWr(A,0xAA) -- upgrade S->M, invalidate core1 --");
    do_op(0, PR_WR, ADDR_A, 32'hAA, rdata, hit); exp_tx++;
    check_eq   ("core0 upgrade reported as HIT",    hit, 1'b1);
    check_state("core0 line0 state == M after upgrade", dbg_state0[0], M_STATE);
    check_eq   ("core0 line0 data == 0xAA",         dbg_data0[0], 32'hAA);
    check_state("core1 line0 INVALIDATED by upgrade",dbg_state1[0], I_STATE);

    // ---- Scenario 4: core0 write miss on B (aliases idx0) -> evicts dirty A, writes back ----
    $display("\n-- Scenario 4: core0 PrWr(B,0xCC) -- write miss forces eviction+writeback of dirty A --");
    do_op(0, PR_WR, ADDR_B, 32'hCC, rdata, hit); exp_tx += 2; // 1 writeback + 1 BusRdX
    check_eq   ("core0 write-miss reported as MISS", hit, 1'b0);
    check_state("core0 line0 state == M (now holds B)", dbg_state0[0], M_STATE);
    check_eq   ("core0 line0 tag == tag(B)=2",       dbg_tag0[0],   2);
    check_eq   ("core0 line0 data == 0xCC",          dbg_data0[0], 32'hCC);
    check_eq   ("main memory[A] updated by writeback (0xAA)",
                dut.u_bus.u_mem.mem[ADDR_A], 32'hAA);

    // ---- Scenario 4b: core0 reads B back -- must be a cache HIT, no new bus transaction ----
    $display("\n-- Scenario 4b: core0 PrRd(B) -- must HIT in cache, no bus transaction --");
    do_op(0, PR_RD, ADDR_B, '0, rdata, hit); // exp_tx unchanged (hit)
    check_eq   ("core0 re-read of B is a HIT",       hit, 1'b1);
    check_eq   ("core0 re-read of B returns 0xCC",   rdata, 32'hCC);
    check_eq   ("bus transaction count unchanged on hit", stat_transactions, exp_tx);

    // ---- Scenario 5: core1 reads A again -- core0 no longer has tag(A), memory holds writeback value ----
    $display("\n-- Scenario 5: core1 PrRd(A) -- core0 evicted A, memory serves the written-back value --");
    do_op(1, PR_RD, ADDR_A, '0, rdata, hit); exp_tx++;
    check_eq   ("core1 reads back the WRITTEN-BACK value 0xAA", rdata, 32'hAA);
    check_state("core1 line0 state == S",            dbg_state1[0], S_STATE);

    // ---- Scenario 6: core1 write hit -> upgrade (core0 unaffected, different tag) ----
    $display("\n-- Scenario 6: core1 PrWr(A,0x77) -- upgrade S->M --");
    do_op(1, PR_WR, ADDR_A, 32'h77, rdata, hit); exp_tx++;
    check_state("core1 line0 state == M",            dbg_state1[0], M_STATE);
    check_eq   ("core1 line0 data == 0x77",           dbg_data1[0], 32'h77);

    // ---- Scenario 7: core0 read miss on independent line E ----
    $display("\n-- Scenario 7: core0 PrRd(E) -- independent cold line --");
    do_op(0, PR_RD, ADDR_E, '0, rdata, hit); exp_tx++;
    check_eq   ("core0 reads mem[E]=5",               rdata, 32'h5);
    check_state("core0 line1 state == S",             dbg_state0[1], S_STATE);

    // ---- Scenario 8: core0 write hit -> upgrade on E ----
    $display("\n-- Scenario 8: core0 PrWr(E,0x99) -- upgrade S->M --");
    do_op(0, PR_WR, ADDR_E, 32'h99, rdata, hit); exp_tx++;
    check_state("core0 line1 state == M",             dbg_state0[1], M_STATE);

    // ---- Scenario 9: core1 reads E -- forces writeback + downgrade of core0's M line ----
    $display("\n-- Scenario 9: core1 PrRd(E) -- remote read of Modified line (writeback + downgrade) --");
    do_op(1, PR_RD, ADDR_E, '0, rdata, hit); exp_tx++;
    check_eq   ("core1 reads the DIRTY value 0x99 via snoop", rdata, 32'h99);
    check_state("core0 line1 DOWNGRADED M->S",         dbg_state0[1], S_STATE);
    check_state("core1 line1 state == S",              dbg_state1[1], S_STATE);
    check_eq   ("main memory[E] updated by snoop writeback",
                dut.u_bus.u_mem.mem[ADDR_E], 32'h99);

    // ---- Scenario 10: bus transaction accounting ----
    $display("\n-- Scenario 10: bus transaction counter sanity --");
    check_eq("total bus transactions matches expected protocol trace",
             stat_transactions, exp_tx);

    // ---- Scenario 11: true concurrent contention -- both cores issue a
    // request in the SAME cycle to two different, never-before-touched
    // addresses. Exercises the round-robin arbiter directly. Driven
    // manually (rather than via two concurrent do_op calls) for
    // unambiguous same-cycle timing. ----
    $display("\n-- Scenario 11: concurrent core0/core1 requests -- arbiter contention --");
    @(posedge clk);
    p0_req_valid <= 1'b1; p0_req_op <= PR_RD; p0_req_addr <= 8'h32; p0_req_wdata <= '0;
    p1_req_valid <= 1'b1; p1_req_op <= PR_RD; p1_req_addr <= 8'h33; p1_req_wdata <= '0;
    @(posedge clk);
    p0_req_valid <= 1'b0;
    p1_req_valid <= 1'b0;
    fork
      begin : wait_c0
        while (!p0_resp_valid) @(posedge clk);
        check_eq("core0 concurrent read returns mem[0x32]", p0_resp_rdata, 32'h32);
      end
      begin : wait_c1
        while (!p1_resp_valid) @(posedge clk);
        check_eq("core1 concurrent read returns mem[0x33]", p1_resp_rdata, 32'h33);
      end
    join
    @(posedge clk);
    exp_tx += 2;
    check_eq("bus transaction count after concurrent contention",
             stat_transactions, exp_tx);
    check_state("core0 line2 holds 0x32 as S", dbg_state0[2], S_STATE);
    check_eq   ("core0 line2 DATA array == 0x32", dbg_data0[2], 32'h32);
    check_state("core1 line3 holds 0x33 as S", dbg_state1[3], S_STATE);

    // ---- Final summary ----
    repeat (5) @(posedge clk);
    $display("\n================================================================");
    $display(" RESULTS: %0d PASSED, %0d FAILED, %0d INVARIANT VIOLATIONS",
              pass_count, fail_count, invariant_violations);
    if (fail_count == 0 && invariant_violations == 0)
      $display(" STATUS: ALL TESTS PASSED - MSI coherence verified.");
    else
      $display(" STATUS: FAILURES DETECTED - see log above.");
    $display("================================================================");

    $finish;
  end

  initial begin
    $dumpfile("wave.vcd");
    $dumpvars(0, tb_dual_core_msi);
  end

  // Safety timeout
  initial begin
    #100000;
    $display("[TIMEOUT] Simulation did not finish in time - possible deadlock.");
    $finish;
  end

endmodule : tb_dual_core_msi
