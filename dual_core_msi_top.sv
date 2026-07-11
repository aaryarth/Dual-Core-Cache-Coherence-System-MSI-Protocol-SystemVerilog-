//=============================================================================
// dual_core_msi_top.sv
// Top level: two cache_core instances + one coherence_bus (with embedded
// main_memory). Exposes a simple processor-style interface per core plus
// debug arrays so the testbench can directly observe MSI state.
//=============================================================================
module dual_core_msi_top
  import msi_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,

  // ------------------------- core0 processor port -------------------------
  input  logic                    p0_req_valid,
  input  pr_op_t                  p0_req_op,
  input  logic [ADDR_WIDTH-1:0]   p0_req_addr,
  input  logic [DATA_WIDTH-1:0]   p0_req_wdata,
  output logic                    p0_req_ready,
  output logic                    p0_resp_valid,
  output logic [DATA_WIDTH-1:0]   p0_resp_rdata,
  output logic                    p0_resp_hit,

  // ------------------------- core1 processor port -------------------------
  input  logic                    p1_req_valid,
  input  pr_op_t                  p1_req_op,
  input  logic [ADDR_WIDTH-1:0]   p1_req_addr,
  input  logic [DATA_WIDTH-1:0]   p1_req_wdata,
  output logic                    p1_req_ready,
  output logic                    p1_resp_valid,
  output logic [DATA_WIDTH-1:0]   p1_resp_rdata,
  output logic                    p1_resp_hit,

  // ------------------------- debug visibility -------------------------
  output logic [NUM_LINES-1:0][1:0]            dbg_state0_packed,
  output logic [NUM_LINES-1:0][TAG_WIDTH-1:0]  dbg_tag0_packed,
  output logic [NUM_LINES-1:0][DATA_WIDTH-1:0] dbg_data0_packed,
  output logic [NUM_LINES-1:0][1:0]            dbg_state1_packed,
  output logic [NUM_LINES-1:0][TAG_WIDTH-1:0]  dbg_tag1_packed,
  output logic [NUM_LINES-1:0][DATA_WIDTH-1:0] dbg_data1_packed,
  output logic [31:0]             stat_transactions
);

  // core0 <-> bus
  logic                   c0_req_valid, c0_gnt, c0_resp_valid, c0_resp_shared;
  bus_cmd_t               c0_req_cmd;
  logic [ADDR_WIDTH-1:0]  c0_req_addr;
  logic [DATA_WIDTH-1:0]  c0_req_wdata, c0_resp_data;

  logic                   c0_sn_valid, c0_sn_resp_valid, c0_sn_resp_hit, c0_sn_resp_was_m;
  bus_cmd_t               c0_sn_cmd;
  logic [ADDR_WIDTH-1:0]  c0_sn_addr;
  logic [DATA_WIDTH-1:0]  c0_sn_resp_data;

  // core1 <-> bus
  logic                   c1_req_valid, c1_gnt, c1_resp_valid, c1_resp_shared;
  bus_cmd_t               c1_req_cmd;
  logic [ADDR_WIDTH-1:0]  c1_req_addr;
  logic [DATA_WIDTH-1:0]  c1_req_wdata, c1_resp_data;

  logic                   c1_sn_valid, c1_sn_resp_valid, c1_sn_resp_hit, c1_sn_resp_was_m;
  bus_cmd_t               c1_sn_cmd;
  logic [ADDR_WIDTH-1:0]  c1_sn_addr;
  logic [DATA_WIDTH-1:0]  c1_sn_resp_data;

  cache_core #(.CORE_ID(0)) u_core0 (
    .clk (clk), .rst_n (rst_n),

    .p_req_valid (p0_req_valid), .p_req_op (p0_req_op),
    .p_req_addr  (p0_req_addr),  .p_req_wdata (p0_req_wdata),
    .p_req_ready (p0_req_ready), .p_resp_valid (p0_resp_valid),
    .p_resp_rdata(p0_resp_rdata),.p_resp_hit   (p0_resp_hit),

    .b_req_valid (c0_req_valid), .b_req_cmd (c0_req_cmd),
    .b_req_addr  (c0_req_addr),  .b_req_wdata (c0_req_wdata),
    .b_gnt       (c0_gnt),
    .b_resp_valid(c0_resp_valid),.b_resp_data (c0_resp_data),
    .b_resp_shared(c0_resp_shared),

    .sn_valid    (c0_sn_valid),  .sn_cmd (c0_sn_cmd), .sn_addr (c0_sn_addr),
    .sn_resp_valid(c0_sn_resp_valid), .sn_resp_hit (c0_sn_resp_hit),
    .sn_resp_was_m(c0_sn_resp_was_m), .sn_resp_data(c0_sn_resp_data),

    .dbg_state_packed (dbg_state0_packed), .dbg_tag_packed (dbg_tag0_packed), .dbg_data_packed (dbg_data0_packed)
  );

  cache_core #(.CORE_ID(1)) u_core1 (
    .clk (clk), .rst_n (rst_n),

    .p_req_valid (p1_req_valid), .p_req_op (p1_req_op),
    .p_req_addr  (p1_req_addr),  .p_req_wdata (p1_req_wdata),
    .p_req_ready (p1_req_ready), .p_resp_valid (p1_resp_valid),
    .p_resp_rdata(p1_resp_rdata),.p_resp_hit   (p1_resp_hit),

    .b_req_valid (c1_req_valid), .b_req_cmd (c1_req_cmd),
    .b_req_addr  (c1_req_addr),  .b_req_wdata (c1_req_wdata),
    .b_gnt       (c1_gnt),
    .b_resp_valid(c1_resp_valid),.b_resp_data (c1_resp_data),
    .b_resp_shared(c1_resp_shared),

    .sn_valid    (c1_sn_valid),  .sn_cmd (c1_sn_cmd), .sn_addr (c1_sn_addr),
    .sn_resp_valid(c1_sn_resp_valid), .sn_resp_hit (c1_sn_resp_hit),
    .sn_resp_was_m(c1_sn_resp_was_m), .sn_resp_data(c1_sn_resp_data),

    .dbg_state_packed (dbg_state1_packed), .dbg_tag_packed (dbg_tag1_packed), .dbg_data_packed (dbg_data1_packed)
  );

  coherence_bus u_bus (
    .clk (clk), .rst_n (rst_n),

    .core0_req_valid (c0_req_valid), .core0_req_cmd (c0_req_cmd),
    .core0_req_addr  (c0_req_addr),  .core0_req_wdata (c0_req_wdata),
    .core0_gnt       (c0_gnt),
    .core0_resp_valid(c0_resp_valid),.core0_resp_data (c0_resp_data),
    .core0_resp_shared(c0_resp_shared),

    .core0_sn_valid  (c0_sn_valid),  .core0_sn_cmd (c0_sn_cmd), .core0_sn_addr (c0_sn_addr),
    .core0_sn_resp_valid(c0_sn_resp_valid), .core0_sn_resp_hit (c0_sn_resp_hit),
    .core0_sn_resp_was_m(c0_sn_resp_was_m), .core0_sn_resp_data(c0_sn_resp_data),

    .core1_req_valid (c1_req_valid), .core1_req_cmd (c1_req_cmd),
    .core1_req_addr  (c1_req_addr),  .core1_req_wdata (c1_req_wdata),
    .core1_gnt       (c1_gnt),
    .core1_resp_valid(c1_resp_valid),.core1_resp_data (c1_resp_data),
    .core1_resp_shared(c1_resp_shared),

    .core1_sn_valid  (c1_sn_valid),  .core1_sn_cmd (c1_sn_cmd), .core1_sn_addr (c1_sn_addr),
    .core1_sn_resp_valid(c1_sn_resp_valid), .core1_sn_resp_hit (c1_sn_resp_hit),
    .core1_sn_resp_was_m(c1_sn_resp_was_m), .core1_sn_resp_data(c1_sn_resp_data),

    .stat_transactions (stat_transactions)
  );

endmodule : dual_core_msi_top
