//=============================================================================
// coherence_bus.sv
// Central snooping bus + arbiter for the dual-core MSI system.
// Owns the single shared main_memory instance.
//
// One transaction at a time. Sequence per transaction:
//   BIDLE       -> pick a winner (round robin if both request simultaneously)
//   BGNT        -> grant winner, broadcast snoop to the loser (unless BusWB)
//   BSNOOP_WAIT -> capture loser's snoop response
//   BMEM        -> resolve against memory / snoop result
//   BRESP       -> return response to winner
//=============================================================================
module coherence_bus
  import msi_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  // --------------------------- core0 master ---------------------------
  input  logic                    core0_req_valid,
  input  bus_cmd_t                core0_req_cmd,
  input  logic [ADDR_WIDTH-1:0]   core0_req_addr,
  input  logic [DATA_WIDTH-1:0]   core0_req_wdata,
  output logic                    core0_gnt,
  output logic                    core0_resp_valid,
  output logic [DATA_WIDTH-1:0]   core0_resp_data,
  output logic                    core0_resp_shared,

  // --------------------------- core0 snoop target ---------------------
  output logic                    core0_sn_valid,
  output bus_cmd_t                core0_sn_cmd,
  output logic [ADDR_WIDTH-1:0]   core0_sn_addr,
  input  logic                    core0_sn_resp_valid,
  input  logic                    core0_sn_resp_hit,
  input  logic                    core0_sn_resp_was_m,
  input  logic [DATA_WIDTH-1:0]   core0_sn_resp_data,

  // --------------------------- core1 master ---------------------------
  input  logic                    core1_req_valid,
  input  bus_cmd_t                core1_req_cmd,
  input  logic [ADDR_WIDTH-1:0]   core1_req_addr,
  input  logic [DATA_WIDTH-1:0]   core1_req_wdata,
  output logic                    core1_gnt,
  output logic                    core1_resp_valid,
  output logic [DATA_WIDTH-1:0]   core1_resp_data,
  output logic                    core1_resp_shared,

  // --------------------------- core1 snoop target ---------------------
  output logic                    core1_sn_valid,
  output bus_cmd_t                core1_sn_cmd,
  output logic [ADDR_WIDTH-1:0]   core1_sn_addr,
  input  logic                    core1_sn_resp_valid,
  input  logic                    core1_sn_resp_hit,
  input  logic                    core1_sn_resp_was_m,
  input  logic [DATA_WIDTH-1:0]   core1_sn_resp_data,

  // --------------------------- stats / debug ---------------------------
  output logic [31:0]             stat_transactions
);

  typedef enum logic [2:0] {BIDLE, BGNT, BSNOOP_WAIT, BMEM, BRESP} bus_state_t;

  bus_state_t bus_state_q;
  logic       rr_priority_q;     // round robin: 0 favors core0, 1 favors core1
  logic       winner_q;          // 0 = core0 won, 1 = core1 won
  bus_cmd_t   tr_cmd_q;
  logic [ADDR_WIDTH-1:0]  tr_addr_q;
  logic [DATA_WIDTH-1:0]  tr_wdata_q;
  logic                   tr_sn_hit_q, tr_sn_wasm_q;
  logic [DATA_WIDTH-1:0]  tr_sn_data_q;
  logic [DATA_WIDTH-1:0]  resp_data_q;
  logic                   resp_shared_q;

  // Memory port (driven combinationally from FSM state)
  logic [ADDR_WIDTH-1:0]  mem_addr;
  logic                   mem_wr_en;
  logic [DATA_WIDTH-1:0]  mem_wdata;
  logic [DATA_WIDTH-1:0]  mem_rdata;

  main_memory u_mem (
    .clk   (clk),
    .rst_n (rst_n),
    .addr  (mem_addr),
    .wr_en (mem_wr_en),
    .wdata (mem_wdata),
    .rdata (mem_rdata)
  );

  // Combinational helper: result of resolving BMEM this cycle
  logic [DATA_WIDTH-1:0] resp_data_c;
  logic                  resp_shared_c;

  always_comb begin
    mem_addr      = tr_addr_q;
    mem_wr_en     = 1'b0;
    mem_wdata     = '0;
    resp_data_c   = '0;
    resp_shared_c = 1'b0;

    // IMPORTANT: only evaluate/act on tr_cmd_q / tr_sn_*_q during the BMEM
    // state. Those registers hold values captured for THIS transaction only
    // once BSNOOP_WAIT has completed; outside of BMEM they may still be
    // showing stale leftovers from the previous transaction, and must not
    // be allowed to drive a write into main_memory.
    if (bus_state_q == BMEM) begin
      unique case (tr_cmd_q)
        CMD_WB: begin
          mem_wr_en   = 1'b1;
          mem_wdata   = tr_wdata_q;
          resp_data_c = tr_wdata_q;
        end
        CMD_RD: begin
          if (tr_sn_hit_q && tr_sn_wasm_q) begin
            mem_wr_en   = 1'b1;
            mem_wdata   = tr_sn_data_q;
            resp_data_c = tr_sn_data_q;
          end else begin
            resp_data_c = mem_rdata;
          end
          resp_shared_c = tr_sn_hit_q;
        end
        CMD_RDX: begin
          if (tr_sn_hit_q && tr_sn_wasm_q) begin
            mem_wr_en = 1'b1;
            mem_wdata = tr_sn_data_q;   // flush old owner's dirty data for memory consistency
          end
          resp_data_c   = tr_wdata_q;   // requester overwrites the whole line anyway
          resp_shared_c = 1'b0;
        end
        CMD_UPGR: begin
          resp_data_c   = tr_wdata_q;
          resp_shared_c = 1'b0;
        end
        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Output (Mealy) combinational drives
  // ------------------------------------------------------------------
  always_comb begin
    core0_gnt = 1'b0; core1_gnt = 1'b0;
    core0_sn_valid = 1'b0; core0_sn_cmd = CMD_NONE; core0_sn_addr = '0;
    core1_sn_valid = 1'b0; core1_sn_cmd = CMD_NONE; core1_sn_addr = '0;
    core0_resp_valid = 1'b0; core0_resp_data = '0; core0_resp_shared = 1'b0;
    core1_resp_valid = 1'b0; core1_resp_data = '0; core1_resp_shared = 1'b0;

    case (bus_state_q)
      BGNT: begin
        if (winner_q == 1'b0) core0_gnt = 1'b1;
        else                  core1_gnt = 1'b1;

        if (tr_cmd_q != CMD_WB) begin
          if (winner_q == 1'b0) begin // winner = core0 -> snoop core1
            core1_sn_valid = 1'b1;
            core1_sn_cmd   = tr_cmd_q;
            core1_sn_addr  = tr_addr_q;
          end else begin              // winner = core1 -> snoop core0
            core0_sn_valid = 1'b1;
            core0_sn_cmd   = tr_cmd_q;
            core0_sn_addr  = tr_addr_q;
          end
        end
      end

      BRESP: begin
        if (winner_q == 1'b0) begin
          core0_resp_valid  = 1'b1;
          core0_resp_data   = resp_data_q;
          core0_resp_shared = resp_shared_q;
        end else begin
          core1_resp_valid  = 1'b1;
          core1_resp_data   = resp_data_q;
          core1_resp_shared = resp_shared_q;
        end
      end

      default: ;
    endcase
  end

  // ------------------------------------------------------------------
  // State register / sequential transaction bookkeeping
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bus_state_q       <= BIDLE;
      rr_priority_q     <= 1'b0;
      winner_q          <= 1'b0;
      tr_cmd_q          <= CMD_NONE;
      tr_addr_q         <= '0;
      tr_wdata_q        <= '0;
      tr_sn_hit_q       <= 1'b0;
      tr_sn_wasm_q      <= 1'b0;
      tr_sn_data_q      <= '0;
      resp_data_q       <= '0;
      resp_shared_q     <= 1'b0;
      stat_transactions <= 32'd0;
    end else begin
      case (bus_state_q)

        BIDLE: begin
          if (core0_req_valid || core1_req_valid) begin
            logic w;
            w = (core0_req_valid && core1_req_valid) ? rr_priority_q :
                (core1_req_valid ? 1'b1 : 1'b0);
            winner_q   <= w;
            tr_cmd_q   <= w ? core1_req_cmd   : core0_req_cmd;
            tr_addr_q  <= w ? core1_req_addr  : core0_req_addr;
            tr_wdata_q <= w ? core1_req_wdata : core0_req_wdata;
            if (core0_req_valid && core1_req_valid) rr_priority_q <= ~rr_priority_q;
            bus_state_q <= BGNT;
          end
        end

        BGNT: begin
          bus_state_q <= BSNOOP_WAIT;
        end

        BSNOOP_WAIT: begin
          // loser = !winner_q
          tr_sn_hit_q  <= winner_q ? core0_sn_resp_hit   : core1_sn_resp_hit;
          tr_sn_wasm_q <= winner_q ? core0_sn_resp_was_m : core1_sn_resp_was_m;
          tr_sn_data_q <= winner_q ? core0_sn_resp_data  : core1_sn_resp_data;
          bus_state_q  <= BMEM;
        end

        BMEM: begin
          resp_data_q   <= resp_data_c;
          resp_shared_q <= resp_shared_c;
          bus_state_q   <= BRESP;
        end

        BRESP: begin
          stat_transactions <= stat_transactions + 32'd1;
          bus_state_q <= BIDLE;
        end

        default: bus_state_q <= BIDLE;
      endcase
    end
  end

endmodule : coherence_bus
