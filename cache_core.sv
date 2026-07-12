//=============================================================================
// cache_core.sv
// Single-core direct-mapped L1 cache with a snooping MSI coherence con//=============================================================================
// cache_core.sv
// Single-core direct-mapped L1 cache with a snooping MSI coherence controller.
//
// Two concurrent pieces of logic live here:
//   1. The "owner" FSM: services this core's own processor requests
//      (PrRd/PrWr), issuing bus transactions on cache misses / upgrades,
//      and handling silent write-back on dirty-line eviction.
//   2. The "snoop responder": watches bus transactions issued by the OTHER
//      core and reacts per MSI rules (supply data + downgrade on BusRd,
//      invalidate on BusRdX/BusUpgr).
//=============================================================================
module cache_core
  import msi_pkg::*;
#(
  parameter int CORE_ID = 0
)(
  input  logic                          clk,
  input  logic                          rst_n,

  // ------------------------------------------------------------------
  // Processor-side interface
  // ------------------------------------------------------------------
  input  logic                          p_req_valid,
  input  pr_op_t                        p_req_op,
  input  logic [ADDR_WIDTH-1:0]         p_req_addr,
  input  logic [DATA_WIDTH-1:0]         p_req_wdata,
  output logic                          p_req_ready,
  output logic                          p_resp_valid,
  output logic [DATA_WIDTH-1:0]         p_resp_rdata,
  output logic                          p_resp_hit,     // 1 = cache hit, 0 = miss required bus xn

  // ------------------------------------------------------------------
  // Bus master (request) interface
  // ------------------------------------------------------------------
  output logic                          b_req_valid,
  output bus_cmd_t                      b_req_cmd,
  output logic [ADDR_WIDTH-1:0]         b_req_addr,
  output logic [DATA_WIDTH-1:0]         b_req_wdata,    // used for BusWB writebacks
  input  logic                          b_gnt,
  input  logic                          b_resp_valid,
  input  logic [DATA_WIDTH-1:0]         b_resp_data,
  input  logic                          b_resp_shared,

  // ------------------------------------------------------------------
  // Snoop interface: observe the OTHER core's transaction on the bus
  // ------------------------------------------------------------------
  input  logic                          sn_valid,
  input  bus_cmd_t                      sn_cmd,
  input  logic [ADDR_WIDTH-1:0]         sn_addr,
  output logic                          sn_resp_valid,
  output logic                          sn_resp_hit,    // this cache held the snooped line
  output logic                          sn_resp_was_m,  // ...and it was Modified (must supply data)
  output logic [DATA_WIDTH-1:0]         sn_resp_data,

  // ------------------------------------------------------------------
  // Debug / testbench visibility (full cache array contents).
  // Packed (not unpacked) array ports are used here for maximum
  // simulator portability when crossing module boundaries.
  // ------------------------------------------------------------------
  output logic [NUM_LINES-1:0][1:0]            dbg_state_packed,
  output logic [NUM_LINES-1:0][TAG_WIDTH-1:0]   dbg_tag_packed,
  output logic [NUM_LINES-1:0][DATA_WIDTH-1:0]  dbg_data_packed
);

  // ------------------------------------------------------------------
  // Cache storage arrays (direct mapped)
  // ------------------------------------------------------------------
  msi_state_t              state_arr [NUM_LINES];
  logic [TAG_WIDTH-1:0]    tag_arr   [NUM_LINES];
  logic [DATA_WIDTH-1:0]   data_arr  [NUM_LINES];

  always_comb begin
    for (int i = 0; i < NUM_LINES; i++) begin
      dbg_state_packed[i] = state_arr[i];
      dbg_tag_packed[i]   = tag_arr[i];
      dbg_data_packed[i]  = data_arr[i];
    end
  end

  function logic [LINE_IDX_BITS-1:0] idx_of(input logic [ADDR_WIDTH-1:0] a);
    return a[LINE_IDX_BITS-1:0];
  endfunction

  function logic [TAG_WIDTH-1:0] tag_of(input logic [ADDR_WIDTH-1:0] a);
    return a[ADDR_WIDTH-1:LINE_IDX_BITS];
  endfunction

  // ------------------------------------------------------------------
  // Owner FSM
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    F_IDLE,
    F_CHECK,
    F_EVICT_REQ,
    F_EVICT_WAIT,
    F_MISS_REQ,
    F_MISS_WAIT,
    F_UPGR_REQ,
    F_UPGR_WAIT,
    F_DONE
  } fsm_t;

  fsm_t fsm_q;

  logic [ADDR_WIDTH-1:0]  cur_addr_q;
  logic [DATA_WIDTH-1:0]  cur_wdata_q;
  pr_op_t                 cur_op_q;
  logic [LINE_IDX_BITS-1:0] cur_idx_q;
  logic [TAG_WIDTH-1:0]     cur_tag_q;
  bus_cmd_t                 pending_cmd_q;   // CMD_RD or CMD_RDX to issue after any eviction
  logic                     was_hit_q;

  assign p_req_ready = (fsm_q == F_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fsm_q         <= F_IDLE;
      p_resp_valid  <= 1'b0;
      p_resp_rdata  <= '0;
      p_resp_hit    <= 1'b0;
      b_req_valid   <= 1'b0;
      b_req_cmd     <= CMD_NONE;
      b_req_addr    <= '0;
      b_req_wdata   <= '0;
      cur_addr_q    <= '0;
      cur_wdata_q   <= '0;
      cur_op_q      <= PR_RD;
      cur_idx_q     <= '0;
      cur_tag_q     <= '0;
      pending_cmd_q <= CMD_NONE;
      was_hit_q     <= 1'b0;

      for (int i = 0; i < NUM_LINES; i++) begin
        state_arr[i] <= I_STATE;
        tag_arr[i]   <= '0;
        data_arr[i]  <= '0;
      end
    end else begin

      p_resp_valid <= 1'b0;   // default: 1-cycle pulse
      b_req_valid  <= 1'b0;   // default deassert (re-asserted while waiting for gnt)

      // ---------------- Snoop responder can fire on any cycle other than
      // when this core's own snooped index is simultaneously being
      // written by its own FSM. The arbiter guarantees only the losing
      // core is snooped, and the losing core's FSM is otherwise idle or
      // stalled waiting for the grant, so there is no structural conflict.
      if (sn_valid) begin
        logic [LINE_IDX_BITS-1:0] sidx;
        logic [TAG_WIDTH-1:0]     stag;
        logic                     local_hit;
        sidx      = idx_of(sn_addr);
        stag      = tag_of(sn_addr);
        local_hit = (tag_arr[sidx] == stag) && (state_arr[sidx] != I_STATE);

        if (local_hit) begin
          unique case (sn_cmd)
            CMD_RD: begin
              // Supply data if dirty, downgrade to Shared either way
              if (state_arr[sidx] == M_STATE) state_arr[sidx] <= S_STATE;
            end
            CMD_RDX, CMD_UPGR: begin
              state_arr[sidx] <= I_STATE;   // invalidate
            end
            default: ;
          endcase
        end
      end

      // ---------------- Owner FSM ----------------
      case (fsm_q)

        F_IDLE: begin
          if (p_req_valid) begin
            cur_addr_q  <= p_req_addr;
            cur_wdata_q <= p_req_wdata;
            cur_op_q    <= p_req_op;
            cur_idx_q   <= idx_of(p_req_addr);
            cur_tag_q   <= tag_of(p_req_addr);
            fsm_q       <= F_CHECK;
          end
        end

        F_CHECK: begin
          logic hit;
          hit = (tag_arr[cur_idx_q] == cur_tag_q) &&
                (state_arr[cur_idx_q] != I_STATE);
          if (cur_op_q == PR_RD) begin
            if (hit) begin
              p_resp_rdata <= data_arr[cur_idx_q];
              p_resp_hit   <= 1'b1;
              p_resp_valid <= 1'b1;
              fsm_q        <= F_IDLE;
            end else begin
              pending_cmd_q <= CMD_RD;
              was_hit_q     <= 1'b0;
              if (state_arr[cur_idx_q] == M_STATE && tag_arr[cur_idx_q] != cur_tag_q)
                fsm_q <= F_EVICT_REQ;
              else
                fsm_q <= F_MISS_REQ;
            end
          end else begin // PR_WR
            if (hit && state_arr[cur_idx_q] == M_STATE) begin
              data_arr[cur_idx_q] <= cur_wdata_q;
              p_resp_rdata         <= cur_wdata_q;
              p_resp_hit           <= 1'b1;
              p_resp_valid         <= 1'b1;
              fsm_q                <= F_IDLE;
            end else if (hit && state_arr[cur_idx_q] == S_STATE) begin
              fsm_q <= F_UPGR_REQ;
            end else begin
              pending_cmd_q <= CMD_RDX;
              was_hit_q     <= 1'b0;
              if (state_arr[cur_idx_q] == M_STATE && tag_arr[cur_idx_q] != cur_tag_q)
                fsm_q <= F_EVICT_REQ;
              else
                fsm_q <= F_MISS_REQ;
            end
          end
        end

        // ---- Silent write-back of a dirty victim line before replacing it
        F_EVICT_REQ: begin
          b_req_valid <= 1'b1;
          b_req_cmd   <= CMD_WB;
          b_req_addr  <= {tag_arr[cur_idx_q], cur_idx_q};
          b_req_wdata <= data_arr[cur_idx_q];
          if (b_gnt) fsm_q <= F_EVICT_WAIT;
        end

        F_EVICT_WAIT: begin
          if (b_resp_valid) begin
            state_arr[cur_idx_q] <= I_STATE;
            fsm_q <= F_MISS_REQ;
          end
        end

        // ---- Read miss (BusRd) or write miss (BusRdX)
        F_MISS_REQ: begin
          b_req_valid <= 1'b1;
          b_req_cmd   <= pending_cmd_q;
          b_req_addr  <= cur_addr_q;
          b_req_wdata <= cur_wdata_q;
          if (b_gnt) fsm_q <= F_MISS_WAIT;
        end

        F_MISS_WAIT: begin
          if (b_resp_valid) begin
            tag_arr[cur_idx_q] <= cur_tag_q;
            if (pending_cmd_q == CMD_RD) begin
              state_arr[cur_idx_q] <= S_STATE;          // MSI has no Exclusive state
              data_arr[cur_idx_q]  <= b_resp_data;
              p_resp_rdata          <= b_resp_data;
            end else begin // CMD_RDX
              state_arr[cur_idx_q] <= M_STATE;
              data_arr[cur_idx_q]  <= cur_wdata_q;
              p_resp_rdata          <= cur_wdata_q;
            end
            p_resp_hit   <= 1'b0;   // this transaction was a miss
            p_resp_valid <= 1'b1;
            fsm_q        <= F_IDLE;
          end
        end

        // ---- Write hit on Shared line -> upgrade to Modified (BusUpgr)
        F_UPGR_REQ: begin
          b_req_valid <= 1'b1;
          b_req_cmd   <= CMD_UPGR;
          b_req_addr  <= cur_addr_q;
          b_req_wdata <= cur_wdata_q;
          if (b_gnt) fsm_q <= F_UPGR_WAIT;
        end

        F_UPGR_WAIT: begin
          if (b_resp_valid) begin
            state_arr[cur_idx_q] <= M_STATE;
            data_arr[cur_idx_q]  <= cur_wdata_q;
            p_resp_rdata          <= cur_wdata_q;
            p_resp_hit            <= 1'b1;   // upgrade counts as a hit (no data fetch)
            p_resp_valid          <= 1'b1;
            fsm_q                 <= F_IDLE;
          end
        end

        default: fsm_q <= F_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Snoop response (registered, 1 cycle after sn_valid is asserted -
  // matches the bus arbiter's expected timing, see coherence_bus.sv)
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sn_resp_valid <= 1'b0;
      sn_resp_hit   <= 1'b0;
      sn_resp_was_m <= 1'b0;
      sn_resp_data  <= '0;
    end else begin
      sn_resp_valid <= sn_valid;
      if (sn_valid) begin
        logic [LINE_IDX_BITS-1:0] sidx;
        logic [TAG_WIDTH-1:0]     stag;
        logic                     local_hit;
        sidx      = idx_of(sn_addr);
        stag      = tag_of(sn_addr);
        local_hit = (tag_arr[sidx] == stag) && (state_arr[sidx] != I_STATE);
        sn_resp_hit   <= local_hit;
        sn_resp_was_m <= local_hit && (state_arr[sidx] == M_STATE);
        sn_resp_data  <= data_arr[sidx];
      end
    end
  end

endmodule : cache_coretroller.
//
// Two concurrent pieces of logic live here:
//   1. The "owner" FSM: services this core's own processor requests
//      (PrRd/PrWr), issuing bus transactions on cache misses / upgrades,
//      and handling silent write-back on dirty-line eviction.
//   2. The "snoop responder": watches bus transactions issued by the OTHER
//      core and reacts per MSI rules (supply data + downgrade on BusRd,
//      invalidate on BusRdX/BusUpgr).
//=============================================================================
module cache_core
  import msi_pkg::*;
#(
  parameter int CORE_ID = 0
)(
  input  logic                          clk,
  input  logic                          rst_n,

  // ------------------------------------------------------------------
  // Processor-side interface
  // ------------------------------------------------------------------
  input  logic                          p_req_valid,
  input  pr_op_t                        p_req_op,
  input  logic [ADDR_WIDTH-1:0]         p_req_addr,
  input  logic [DATA_WIDTH-1:0]         p_req_wdata,
  output logic                          p_req_ready,
  output logic                          p_resp_valid,
  output logic [DATA_WIDTH-1:0]         p_resp_rdata,
  output logic                          p_resp_hit,     // 1 = cache hit, 0 = miss required bus xn

  // ------------------------------------------------------------------
  // Bus master (request) interface
  // ------------------------------------------------------------------
  output logic                          b_req_valid,
  output bus_cmd_t                      b_req_cmd,
  output logic [ADDR_WIDTH-1:0]         b_req_addr,
  output logic [DATA_WIDTH-1:0]         b_req_wdata,    // used for BusWB writebacks
  input  logic                          b_gnt,
  input  logic                          b_resp_valid,
  input  logic [DATA_WIDTH-1:0]         b_resp_data,
  input  logic                          b_resp_shared,

  // ------------------------------------------------------------------
  // Snoop interface: observe the OTHER core's transaction on the bus
  // ------------------------------------------------------------------
  input  logic                          sn_valid,
  input  bus_cmd_t                      sn_cmd,
  input  logic [ADDR_WIDTH-1:0]         sn_addr,
  output logic                          sn_resp_valid,
  output logic                          sn_resp_hit,    // this cache held the snooped line
  output logic                          sn_resp_was_m,  // ...and it was Modified (must supply data)
  output logic [DATA_WIDTH-1:0]         sn_resp_data,

  // ------------------------------------------------------------------
  // Debug / testbench visibility (full cache array contents).
  // Packed (not unpacked) array ports are used here for maximum
  // simulator portability when crossing module boundaries.
  // ------------------------------------------------------------------
  output logic [NUM_LINES-1:0][1:0]            dbg_state_packed,
  output logic [NUM_LINES-1:0][TAG_WIDTH-1:0]   dbg_tag_packed,
  output logic [NUM_LINES-1:0][DATA_WIDTH-1:0]  dbg_data_packed
);

  // ------------------------------------------------------------------
  // Cache storage arrays (direct mapped)
  // ------------------------------------------------------------------
  msi_state_t              state_arr [NUM_LINES];
  logic [TAG_WIDTH-1:0]    tag_arr   [NUM_LINES];
  logic [DATA_WIDTH-1:0]   data_arr  [NUM_LINES];

  always_comb begin
    for (int i = 0; i < NUM_LINES; i++) begin
      dbg_state_packed[i] = state_arr[i];
      dbg_tag_packed[i]   = tag_arr[i];
      dbg_data_packed[i]  = data_arr[i];
    end
  end

  function logic [LINE_IDX_BITS-1:0] idx_of(input logic [ADDR_WIDTH-1:0] a);
    return a[LINE_IDX_BITS-1:0];
  endfunction

  function logic [TAG_WIDTH-1:0] tag_of(input logic [ADDR_WIDTH-1:0] a);
    return a[ADDR_WIDTH-1:LINE_IDX_BITS];
  endfunction

  // ------------------------------------------------------------------
  // Owner FSM
  // ------------------------------------------------------------------
  typedef enum logic [3:0] {
    F_IDLE,
    F_CHECK,
    F_EVICT_REQ,
    F_EVICT_WAIT,
    F_MISS_REQ,
    F_MISS_WAIT,
    F_UPGR_REQ,
    F_UPGR_WAIT,
    F_DONE
  } fsm_t;

  fsm_t fsm_q;

  logic [ADDR_WIDTH-1:0]  cur_addr_q;
  logic [DATA_WIDTH-1:0]  cur_wdata_q;
  pr_op_t                 cur_op_q;
  logic [LINE_IDX_BITS-1:0] cur_idx_q;
  logic [TAG_WIDTH-1:0]     cur_tag_q;
  bus_cmd_t                 pending_cmd_q;   // CMD_RD or CMD_RDX to issue after any eviction
  logic                     was_hit_q;

  assign p_req_ready = (fsm_q == F_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fsm_q         <= F_IDLE;
      p_resp_valid  <= 1'b0;
      p_resp_rdata  <= '0;
      p_resp_hit    <= 1'b0;
      b_req_valid   <= 1'b0;
      b_req_cmd     <= CMD_NONE;
      b_req_addr    <= '0;
      b_req_wdata   <= '0;
      cur_addr_q    <= '0;
      cur_wdata_q   <= '0;
      cur_op_q      <= PR_RD;
      cur_idx_q     <= '0;
      cur_tag_q     <= '0;
      pending_cmd_q <= CMD_NONE;
      was_hit_q     <= 1'b0;

      for (int i = 0; i < NUM_LINES; i++) begin
        state_arr[i] <= I_STATE;
        tag_arr[i]   <= '0;
        data_arr[i]  <= '0;
      end
    end else begin

      p_resp_valid <= 1'b0;   // default: 1-cycle pulse
      b_req_valid  <= 1'b0;   // default deassert (re-asserted while waiting for gnt)

      // ---------------- Snoop responder can fire on any cycle other than
      // when this core's own snooped index is simultaneously being
      // written by its own FSM. The arbiter guarantees only the losing
      // core is snooped, and the losing core's FSM is otherwise idle or
      // stalled waiting for the grant, so there is no structural conflict.
      if (sn_valid) begin
        logic [LINE_IDX_BITS-1:0] sidx;
        logic [TAG_WIDTH-1:0]     stag;
        logic                     local_hit;
        sidx      = idx_of(sn_addr);
        stag      = tag_of(sn_addr);
        local_hit = (tag_arr[sidx] == stag) && (state_arr[sidx] != I_STATE);

        if (local_hit) begin
          unique case (sn_cmd)
            CMD_RD: begin
              // Supply data if dirty, downgrade to Shared either way
              if (state_arr[sidx] == M_STATE) state_arr[sidx] <= S_STATE;
            end
            CMD_RDX, CMD_UPGR: begin
              state_arr[sidx] <= I_STATE;   // invalidate
            end
            default: ;
          endcase
        end
      end

      // ---------------- Owner FSM ----------------
      case (fsm_q)

        F_IDLE: begin
          if (p_req_valid) begin
            cur_addr_q  <= p_req_addr;
            cur_wdata_q <= p_req_wdata;
            cur_op_q    <= p_req_op;
            cur_idx_q   <= idx_of(p_req_addr);
            cur_tag_q   <= tag_of(p_req_addr);
            fsm_q       <= F_CHECK;
          end
        end

        F_CHECK: begin
          logic hit;
          hit = (tag_arr[cur_idx_q] == cur_tag_q) &&
                (state_arr[cur_idx_q] != I_STATE);
          if (cur_op_q == PR_RD) begin
            if (hit) begin
              p_resp_rdata <= data_arr[cur_idx_q];
              p_resp_hit   <= 1'b1;
              p_resp_valid <= 1'b1;
              fsm_q        <= F_IDLE;
            end else begin
              pending_cmd_q <= CMD_RD;
              was_hit_q     <= 1'b0;
              if (state_arr[cur_idx_q] == M_STATE && tag_arr[cur_idx_q] != cur_tag_q)
                fsm_q <= F_EVICT_REQ;
              else
                fsm_q <= F_MISS_REQ;
            end
          end else begin // PR_WR
            if (hit && state_arr[cur_idx_q] == M_STATE) begin
              data_arr[cur_idx_q] <= cur_wdata_q;
              p_resp_rdata         <= cur_wdata_q;
              p_resp_hit           <= 1'b1;
              p_resp_valid         <= 1'b1;
              fsm_q                <= F_IDLE;
            end else if (hit && state_arr[cur_idx_q] == S_STATE) begin
              fsm_q <= F_UPGR_REQ;
            end else begin
              pending_cmd_q <= CMD_RDX;
              was_hit_q     <= 1'b0;
              if (state_arr[cur_idx_q] == M_STATE && tag_arr[cur_idx_q] != cur_tag_q)
                fsm_q <= F_EVICT_REQ;
              else
                fsm_q <= F_MISS_REQ;
            end
          end
        end

        // ---- Silent write-back of a dirty victim line before replacing it
        F_EVICT_REQ: begin
          b_req_valid <= 1'b1;
          b_req_cmd   <= CMD_WB;
          b_req_addr  <= {tag_arr[cur_idx_q], cur_idx_q};
          b_req_wdata <= data_arr[cur_idx_q];
          if (b_gnt) fsm_q <= F_EVICT_WAIT;
        end

        F_EVICT_WAIT: begin
          if (b_resp_valid) begin
            state_arr[cur_idx_q] <= I_STATE;
            fsm_q <= F_MISS_REQ;
          end
        end

        // ---- Read miss (BusRd) or write miss (BusRdX)
        F_MISS_REQ: begin
          b_req_valid <= 1'b1;
          b_req_cmd   <= pending_cmd_q;
          b_req_addr  <= cur_addr_q;
          b_req_wdata <= cur_wdata_q;
          if (b_gnt) fsm_q <= F_MISS_WAIT;
        end

        F_MISS_WAIT: begin
          if (b_resp_valid) begin
            tag_arr[cur_idx_q] <= cur_tag_q;
            if (pending_cmd_q == CMD_RD) begin
              state_arr[cur_idx_q] <= S_STATE;          // MSI has no Exclusive state
              data_arr[cur_idx_q]  <= b_resp_data;
              p_resp_rdata          <= b_resp_data;
            end else begin // CMD_RDX
              state_arr[cur_idx_q] <= M_STATE;
              data_arr[cur_idx_q]  <= cur_wdata_q;
              p_resp_rdata          <= cur_wdata_q;
            end
            p_resp_hit   <= 1'b0;   // this transaction was a miss
            p_resp_valid <= 1'b1;
            fsm_q        <= F_IDLE;
          end
        end

        // ---- Write hit on Shared line -> upgrade to Modified (BusUpgr)
        F_UPGR_REQ: begin
          b_req_valid <= 1'b1;
          b_req_cmd   <= CMD_UPGR;
          b_req_addr  <= cur_addr_q;
          b_req_wdata <= cur_wdata_q;
          if (b_gnt) fsm_q <= F_UPGR_WAIT;
        end

        F_UPGR_WAIT: begin
          if (b_resp_valid) begin
            state_arr[cur_idx_q] <= M_STATE;
            data_arr[cur_idx_q]  <= cur_wdata_q;
            p_resp_rdata          <= cur_wdata_q;
            p_resp_hit            <= 1'b1;   // upgrade counts as a hit (no data fetch)
            p_resp_valid          <= 1'b1;
            fsm_q                 <= F_IDLE;
          end
        end

        default: fsm_q <= F_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Snoop response (registered, 1 cycle after sn_valid is asserted -
  // matches the bus arbiter's expected timing, see coherence_bus.sv)
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sn_resp_valid <= 1'b0;
      sn_resp_hit   <= 1'b0;
      sn_resp_was_m <= 1'b0;
      sn_resp_data  <= '0;
    end else begin
      sn_resp_valid <= sn_valid;
      if (sn_valid) begin
        logic [LINE_IDX_BITS-1:0] sidx;
        logic [TAG_WIDTH-1:0]     stag;
        logic                     local_hit;
        sidx      = idx_of(sn_addr);
        stag      = tag_of(sn_addr);
        local_hit = (tag_arr[sidx] == stag) && (state_arr[sidx] != I_STATE);
        sn_resp_hit   <= local_hit;
        sn_resp_was_m <= local_hit && (state_arr[sidx] == M_STATE);
        sn_resp_data  <= data_arr[sidx];
      end
    end
  end

endmodule : cache_core
