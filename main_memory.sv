//=============================================================================
// main_memory.sv
// Simple shared main memory. Combinational read, synchronous write.
// Initialized so mem[addr] == addr, which makes expected values in the
// testbench trivial to predict for any address that hasn't been written yet.
//=============================================================================
module main_memory
  import msi_pkg::*;
(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic [ADDR_WIDTH-1:0]   addr,
  input  logic                    wr_en,
  input  logic [DATA_WIDTH-1:0]   wdata,
  output logic [DATA_WIDTH-1:0]   rdata
);

  logic [DATA_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];

  integer i;
  initial begin
    for (i = 0; i < (1<<ADDR_WIDTH); i = i + 1)
      mem[i] = i[DATA_WIDTH-1:0];
  end

  assign rdata = mem[addr];

  always_ff @(posedge clk) begin
    if (wr_en) mem[addr] <= wdata;
  end

endmodule : main_memory
